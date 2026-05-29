# 测试修改的地方：1. train_cuts; filter; 0 and validation; fps 5000->100
"""
Usage:

conda activate myenv2

export PYTHONPATH=/inspire/hdd/project/embodied-multimodality/chenxie-25019/chonghao/icefall:$PYTHONPATH

cd /inspire/hdd/project/embodied-multimodality/chenxie-25019/chonghao/icefall/egs/multi_zh_en/ASR

export CUDA_VISIBLE_DEVICES="0,1,2,3"

# For non-streaming model training:
python ./zipformer/train.py \
  --world-size 1 \
  --num-epochs 2 \
  --start-epoch 1 \
  --use-bf16 1 \
  --exp-dir zipformer/exp1 \
  --max-duration 3600 \
  --bpe-model data/lang_new/bpe.model \
  --num-workers 20 \
  --on-the-fly-feats True \
  --input-strategy AudioSamples \
  --num-encoder-layers 2,2,4,5,4,2 \
  --feedforward-dim 512,768,1536,2048,1536,768 \
  --encoder-dim 192,256,512,768,512,256 \
  --encoder-unmasked-dim 192,192,256,320,256,192 \
  --causal True
    --start-batch 30000 \

export CUDA_VISIBLE_DEVICES="0,1"
python ./zipformer/train.py \
  --world-size 2 \
  --num-epochs 10 \
  --start-epoch 1 \
  --use-bf16 1 \
  --exp-dir zipformer/exp_test1 \
  --max-duration 3600 \
  --bpe-model data/lang_new/bpe.model \
  --num-workers 8 \
  --on-the-fly-feats True \
  --input-strategy AudioSamples \
  --num-encoder-layers 2,2,4,5,4,2 \
  --feedforward-dim 512,768,1536,2048,1536,768 \
  --encoder-dim 192,256,512,768,512,256 \
  --encoder-unmasked-dim 192,192,256,320,256,192

# For streaming model training:
./zipformer/train.py \
  --world-size 4 \
  --num-epochs 30 \
  --start-epoch 1 \
  --use-fp16 1 \
  --exp-dir zipformer/exp \
  --causal 1 \
  --max-duration 1000

It supports training with:
  - transducer loss (default), with `--use-transducer True --use-ctc False`
  - ctc loss (not recommended), with `--use-transducer False --use-ctc True`
  - transducer loss & ctc loss, with `--use-transducer True --use-ctc True`
"""


import argparse
import copy
import logging
import warnings
from pathlib import Path
from shutil import copyfile
from collections import defaultdict
import math
from typing import Any, Dict, Iterable, Optional, Set, Tuple, Union, List


import k2
import optim
import sentencepiece as spm
import torch
import torch.multiprocessing as mp
import torch.nn as nn
from asr_datamodule import AsrDataModule
from attention_decoder import AttentionDecoderModel
from decoder import Decoder
from joiner import Joiner
from lhotse.cut import Cut
from lhotse.dataset import SpecAugment
from lhotse.dataset.sampling.base import CutSampler
from lhotse.utils import fix_random_seed
from model import AsrModel
from multi_dataset_pc import MultiDataset
from optim import Eden, ScaledAdam
from scaling import ScheduledFloat
from subsampling import Conv2dSubsampling
from torch import Tensor
from torch.nn.parallel import DistributedDataParallel as DDP
from torch.utils.tensorboard import SummaryWriter
from zipformer import Zipformer2

from icefall import byte_encode, diagnostics, smart_byte_decode
from icefall.checkpoint import load_checkpoint, remove_checkpoints
from icefall.checkpoint import save_checkpoint as save_checkpoint_impl
from icefall.checkpoint import (
    save_checkpoint_with_global_batch_idx,
    update_averaged_model,
    average_checkpoints,
    average_checkpoints_with_averaged_model,
    find_checkpoints,
    load_checkpoint,
)
from icefall.dist import cleanup_dist, setup_dist
from icefall.env import get_env_info
from icefall.err import raise_grad_scale_is_too_small_error
from icefall.hooks import register_inf_check_hooks
from icefall.utils import (
    AttributeDict,
    MetricsTracker,
    create_grad_scaler,
    get_parameter_groups_with_lrs,
    setup_logger,
    str2bool,
    # tokenize_by_CJK_char,
    torch_autocast,
    store_transcripts,
    write_error_stats,
)

import time
from pprint import pprint
import json

try:
    import wandb
except ImportError:
    wandb = None

LRSchedulerType = Union[torch.optim.lr_scheduler._LRScheduler, optim.LRScheduler]
# import wandb
import os
from icefall.lexicon import Lexicon
from gigaspeech_scoring import asr_text_post_processing
# 1. 设置离线并初始化
os.environ["WANDB_MODE"] = "offline"

import re
# 之前的版本无法在标点前加空格
def tokenize_by_CJK_char(line: str) -> str:
    # 添加中英文逗号、句号、感叹号、问号、冒号、分号、顿号、人民币符号
    pattern = re.compile(
        r"([\u1100-\u11ff\u2e80-\ua4cf\ua840-\uD7AF\uF900-\uFAFF\uFE30-\uFE4F\uFF65-\uFFDC\U00020000-\U0002FFFF"
        r",.!?;，。？！；：、¥])"
    )
    chars = pattern.split(line.strip())
    return " ".join([w.strip() for w in chars if w.strip()])

def get_adjusted_batch_count(params: AttributeDict) -> float:
    # returns the number of batches we would have used so far if we had used the reference
    # duration.  This is for purposes of set_batch_count().
    return (
        params.batch_idx_train
        * (params.max_duration * params.world_size)
        / params.ref_duration
    )


def set_batch_count(model: Union[nn.Module, DDP], batch_count: float) -> None:
    if isinstance(model, DDP):
        # get underlying nn.Module
        model = model.module
    for name, module in model.named_modules():
        if hasattr(module, "batch_count"):
            module.batch_count = batch_count
        if hasattr(module, "name"):
            module.name = name


VOCAB_REMAP_KEYS = {
    "decoder.embedding.weight",
    "joiner.output_linear.weight",
    "joiner.output_linear.bias",
    "simple_am_proj.weight",
    "simple_am_proj.bias",
    "simple_lm_proj.weight",
    "simple_lm_proj.bias",
    "ctc_output.1.weight",
    "ctc_output.1.bias",
    "attention_decoder.decoder.embed.weight",
    "attention_decoder.decoder.output_layer.weight",
    "attention_decoder.decoder.output_layer.bias",
}


def add_finetune_arguments(parser: argparse.ArgumentParser):
    parser.add_argument(
        "--do-finetune",
        type=str2bool,
        default=False,
        help="If true, initialize model from --finetune-ckpt before training.",
    )

    parser.add_argument(
        "--finetune-ckpt",
        type=str,
        default="",
        help="Checkpoint used only for model initialization.",
    )

    parser.add_argument(
        "--old-bpe-model",
        type=str,
        default="",
        help="The old SentencePiece model used by --finetune-ckpt.",
    )

    parser.add_argument(
        "--finetune-state-src",
        type=str,
        choices=("auto", "model", "model_avg"),
        default="auto",
        help="Which state dict to use from --finetune-ckpt.",
    )

    parser.add_argument(
        "--init-modules",
        type=str,
        default="",
        help=(
            "Comma-separated module prefixes to initialize from the fine-tune "
            "checkpoint. Empty means initialize all compatible modules."
        ),
    )

    parser.add_argument(
        "--use-wandb",
        type=str2bool,
        default=False,
        help="If true, log training metrics to Weights & Biases.",
    )

    parser.add_argument(
        "--wandb-project",
        type=str,
        default="icefall-finetune",
        help="Weights & Biases project name.",
    )

    parser.add_argument(
        "--wandb-name",
        type=str,
        default="",
        help="Optional Weights & Biases run name.",
    )

    parser.add_argument(
        "--wandb-group",
        type=str,
        default="",
        help="Optional Weights & Biases run group.",
    )

    parser.add_argument(
        "--wandb-dir",
        type=str,
        default="",
        help="Optional Weights & Biases local directory.",
    )


def sanitize_for_wandb(value):
    if isinstance(value, dict):
        return {str(k): sanitize_for_wandb(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [sanitize_for_wandb(v) for v in value]
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def strip_module_prefix(state_dict: Dict[str, torch.Tensor]) -> Dict[str, torch.Tensor]:
    if not state_dict:
        return state_dict
    first_key = next(iter(state_dict))
    if not first_key.startswith("module."):
        return state_dict
    return {k[len("module.") :]: v for k, v in state_dict.items()}


def key_allowed(key: str, init_modules: Optional[Set[str]]) -> bool:
    if not init_modules:
        return True
    return any(key == module or key.startswith(f"{module}.") for module in init_modules)


def build_piece_to_id(sp: spm.SentencePieceProcessor) -> Dict[str, int]:
    return {sp.id_to_piece(i): i for i in range(sp.get_piece_size())}


def remap_vocab_rows(
    dst_tensor: torch.Tensor,
    src_tensor: torch.Tensor,
    old_piece2id: Dict[str, int],
    new_piece2id: Dict[str, int],
) -> int:
    copied = 0
    shared_pieces = set(old_piece2id) & set(new_piece2id)
    for piece in shared_pieces:
        old_id = old_piece2id[piece]
        new_id = new_piece2id[piece]
        dst_tensor[new_id].copy_(src_tensor[old_id])
        copied += 1
    return copied


def choose_finetune_state(
    checkpoint: Dict[str, Any], state_source: str
) -> Dict[str, torch.Tensor]:
    if state_source == "model":
        return strip_module_prefix(checkpoint["model"])
    if state_source == "model_avg":
        assert "model_avg" in checkpoint, "Checkpoint does not contain model_avg"
        return strip_module_prefix(checkpoint["model_avg"])
    if "model_avg" in checkpoint and checkpoint["model_avg"] is not None:
        logging.info("Using model_avg from fine-tune checkpoint")
        return strip_module_prefix(checkpoint["model_avg"])
    logging.info("Using model from fine-tune checkpoint")
    return strip_module_prefix(checkpoint["model"])


def load_model_params_with_vocab_remap(
    model: nn.Module,
    ckpt: str,
    new_bpe_model: str,
    old_bpe_model: str = "",
    init_modules: Optional[Iterable[str]] = None,
    state_source: str = "auto",
) -> None:
    logging.info("Loading fine-tune checkpoint from %s", ckpt)
    checkpoint = torch.load(ckpt, map_location="cpu", weights_only=False)
    src_state = choose_finetune_state(checkpoint, state_source)
    dst_state = model.state_dict()

    init_module_set = {m.strip() for m in init_modules if m.strip()} if init_modules else None
    use_vocab_remap = bool(old_bpe_model) and bool(new_bpe_model)

    if use_vocab_remap:
        old_sp = spm.SentencePieceProcessor()
        old_sp.load(old_bpe_model)
        new_sp = spm.SentencePieceProcessor()
        new_sp.load(new_bpe_model)
        old_piece2id = build_piece_to_id(old_sp)
        new_piece2id = build_piece_to_id(new_sp)
    else:
        old_piece2id = {}
        new_piece2id = {}

    loaded_direct = []
    skipped_shape = []
    remapped_keys = []

    for key, src_value in src_state.items():
        if key not in dst_state:
            continue
        if not key_allowed(key, init_module_set):
            continue
        if key in VOCAB_REMAP_KEYS and use_vocab_remap:
            continue
        if dst_state[key].shape != src_value.shape:
            skipped_shape.append((key, tuple(src_value.shape), tuple(dst_state[key].shape)))
            continue
        dst_state[key] = src_value.clone()
        loaded_direct.append(key)

    if use_vocab_remap:
        with torch.no_grad():
            for key in sorted(VOCAB_REMAP_KEYS):
                if key not in src_state or key not in dst_state:
                    continue
                if not key_allowed(key, init_module_set):
                    continue
                copied = remap_vocab_rows(
                    dst_tensor=dst_state[key],
                    src_tensor=src_state[key],
                    old_piece2id=old_piece2id,
                    new_piece2id=new_piece2id,
                )
                remapped_keys.append((key, copied))

    model.load_state_dict(dst_state, strict=False)

    logging.info("Directly loaded %d tensors from fine-tune checkpoint", len(loaded_direct))
    for key, copied in remapped_keys:
        logging.info("Remapped %s with %d shared pieces", key, copied)
    if skipped_shape:
        logging.info("Skipped %d tensors due to shape mismatch", len(skipped_shape))
        for key, old_shape, new_shape in skipped_shape[:20]:
            logging.info("Skipped %s: old=%s new=%s", key, old_shape, new_shape)


def add_model_arguments(parser: argparse.ArgumentParser):
    # parser.add_argument(
    #     "--decoding-method",
    #     type=str,
    #     default="greedy_search",
    #     help=".",
    # )

    parser.add_argument(
        "--wenet-fixed",
        type=bool,
        default=True,
        help=".",
    )

    parser.add_argument(
        "--byte-encode",
        type=bool,
        default=False,
        help=".",
    )

    parser.add_argument(
        "--num-encoder-layers",
        type=str,
        default="2,2,3,4,3,2",
        help="Number of zipformer encoder layers per stack, comma separated.",
    )

    parser.add_argument(
        "--downsampling-factor",
        type=str,
        default="1,2,4,8,4,2",
        help="Downsampling factor for each stack of encoder layers.",
    )

    parser.add_argument(
        "--feedforward-dim",
        type=str,
        default="512,768,1024,1536,1024,768",
        help="Feedforward dimension of the zipformer encoder layers, per stack, comma separated.",
    )

    parser.add_argument(
        "--num-heads",
        type=str,
        default="4,4,4,8,4,4",
        help="Number of attention heads in the zipformer encoder layers: a single int or comma-separated list.",
    )

    parser.add_argument(
        "--encoder-dim",
        type=str,
        default="192,256,384,512,384,256",
        help="Embedding dimension in encoder stacks: a single int or comma-separated list.",
    )

    parser.add_argument(
        "--query-head-dim",
        type=str,
        default="32",
        help="Query/key dimension per head in encoder stacks: a single int or comma-separated list.",
    )

    parser.add_argument(
        "--value-head-dim",
        type=str,
        default="12",
        help="Value dimension per head in encoder stacks: a single int or comma-separated list.",
    )

    parser.add_argument(
        "--pos-head-dim",
        type=str,
        default="4",
        help="Positional-encoding dimension per head in encoder stacks: a single int or comma-separated list.",
    )

    parser.add_argument(
        "--pos-dim",
        type=int,
        default="48",
        help="Positional-encoding embedding dimension",
    )

    parser.add_argument(
        "--encoder-unmasked-dim",
        type=str,
        default="192,192,256,256,256,192",
        help="Unmasked dimensions in the encoders, relates to augmentation during training.  "
        "A single int or comma-separated list.  Must be <= each corresponding encoder_dim.",
    )

    parser.add_argument(
        "--cnn-module-kernel",
        type=str,
        default="31,31,15,15,15,31",
        help="Sizes of convolutional kernels in convolution modules in each encoder stack: "
        "a single int or comma-separated list.",
    )

    parser.add_argument(
        "--decoder-dim",
        type=int,
        default=512,
        help="Embedding dimension in the decoder model.",
    )

    parser.add_argument(
        "--joiner-dim",
        type=int,
        default=512,
        help="""Dimension used in the joiner model.
        Outputs from the encoder and decoder model are projected
        to this dimension before adding.
        """,
    )

    parser.add_argument(
        "--attention-decoder-dim",
        type=int,
        default=512,
        help="""Dimension used in the attention decoder""",
    )

    parser.add_argument(
        "--attention-decoder-num-layers",
        type=int,
        default=6,
        help="""Number of transformer layers used in attention decoder""",
    )

    parser.add_argument(
        "--attention-decoder-attention-dim",
        type=int,
        default=512,
        help="""Attention dimension used in attention decoder""",
    )

    parser.add_argument(
        "--attention-decoder-num-heads",
        type=int,
        default=8,
        help="""Number of attention heads used in attention decoder""",
    )

    parser.add_argument(
        "--attention-decoder-feedforward-dim",
        type=int,
        default=2048,
        help="""Feedforward dimension used in attention decoder""",
    )

    parser.add_argument(
        "--causal",
        type=str2bool,
        default=False,
        help="If True, use causal version of model.",
    )

    parser.add_argument(
        "--chunk-size",
        type=str,
        default="16,32,64,-1",
        help="Chunk sizes (at 50Hz frame rate) will be chosen randomly from this list during training. "
        " Must be just -1 if --causal=False",
    )

    parser.add_argument(
        "--left-context-frames",
        type=str,
        default="64,128,256,-1",
        help="Maximum left-contexts for causal training, measured in frames which will "
        "be converted to a number of chunks.  If splitting into chunks, "
        "chunk left-context frames will be chosen randomly from this list; else not relevant.",
    )

    parser.add_argument(
        "--use-transducer",
        type=str2bool,
        default=True,
        help="If True, use Transducer head.",
    )

    parser.add_argument(
        "--use-ctc",
        type=str2bool,
        default=False,
        help="If True, use CTC head.",
    )

    parser.add_argument(
        "--use-attention-decoder",
        type=str2bool,
        default=False,
        help="If True, use attention-decoder head.",
    )

    parser.add_argument(
        "--use-cr-ctc",
        type=str2bool,
        default=False,
        help="If True, use consistency-regularized CTC.",
    )


def get_parser():
    parser = argparse.ArgumentParser(
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    parser.add_argument(
        "--world-size",
        type=int,
        default=1,
        help="Number of GPUs for DDP training.",
    )

    parser.add_argument(
        "--master-port",
        type=int,
        default=12354,
        help="Master port to use for DDP training.",
    )

    parser.add_argument(
        "--tensorboard",
        type=str2bool,
        default=True,
        help="Should various information be logged in tensorboard.",
    )

    parser.add_argument(
        "--num-epochs",
        type=int,
        default=30,
        help="Number of epochs to train.",
    )

    parser.add_argument(
        "--start-epoch",
        type=int,
        default=1,
        help="""Resume training from this epoch. It should be positive.
        If larger than 1, it will load checkpoint from
        exp-dir/epoch-{start_epoch-1}.pt
        """,
    )

    parser.add_argument(
        "--start-batch",
        type=int,
        default=0,
        help="""If positive, --start-epoch is ignored and
        it loads the checkpoint from exp-dir/checkpoint-{start_batch}.pt
        """,
    )

    parser.add_argument(
        "--exp-dir",
        type=str,
        default="zipformer/exp",
        help="""The experiment dir.
        It specifies the directory where all training related
        files, e.g., checkpoints, log, etc, are saved
        """,
    )

    parser.add_argument(
        "--bpe-model",
        type=str,
        default="data/lang_bbpe_2000/bbpe.model",
        help="Path to the BPE model",
    )

    parser.add_argument(
        "--base-lr", type=float, default=0.045, help="The base learning rate."
    )

    parser.add_argument(
        "--lr-batches",
        type=float,
        default=7500,
        help="""Number of steps that affects how rapidly the learning rate
        decreases. We suggest not to change this.""",
    )

    parser.add_argument(
        "--lr-epochs",
        type=float,
        default=3.5,
        help="""Number of epochs that affects how rapidly the learning rate decreases.
        """,
    )

    parser.add_argument(
        "--ref-duration",
        type=float,
        default=600,
        help="Reference batch duration for purposes of adjusting batch counts for setting various "
        "schedules inside the model",
    )

    parser.add_argument(
        "--context-size",
        type=int,
        default=2,
        help="The context size in the decoder. 1 means bigram; " "2 means tri-gram",
    )

    parser.add_argument(
        "--prune-range",
        type=int,
        default=5,
        help="The prune range for rnnt loss, it means how many symbols(context)"
        "we are using to compute the loss",
    )

    parser.add_argument(
        "--lm-scale",
        type=float,
        default=0.25,
        help="The scale to smooth the loss with lm "
        "(output of prediction network) part.",
    )

    parser.add_argument(
        "--am-scale",
        type=float,
        default=0.0,
        help="The scale to smooth the loss with am (output of encoder network)" "part.",
    )

    parser.add_argument(
        "--simple-loss-scale",
        type=float,
        default=0.5,
        help="To get pruning ranges, we will calculate a simple version"
        "loss(joiner is just addition), this simple loss also uses for"
        "training (as a regularization item). We will scale the simple loss"
        "with this parameter before adding to the final loss.",
    )

    parser.add_argument(
        "--ctc-loss-scale",
        type=float,
        default=0.2,
        help="Scale for CTC loss.",
    )

    parser.add_argument(
        "--cr-loss-scale",
        type=float,
        default=0.2,
        help="Scale for consistency-regularization loss.",
    )

    parser.add_argument(
        "--time-mask-ratio",
        type=float,
        default=2.5,
        help="When using cr-ctc, we increase the amount of time-masking in SpecAugment.",
    )

    parser.add_argument(
        "--attention-decoder-loss-scale",
        type=float,
        default=0.8,
        help="Scale for attention-decoder loss.",
    )

    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="The seed for random generators intended for reproducibility",
    )

    parser.add_argument(
        "--print-diagnostics",
        type=str2bool,
        default=False,
        help="Accumulate stats on activations, print them and exit.",
    )

    parser.add_argument(
        "--inf-check",
        type=str2bool,
        default=False,
        help="Add hooks to check for infinite module outputs and gradients.",
    )

    parser.add_argument(
        "--save-every-n",
        type=int,
        default=4000,
        help="""Save checkpoint after processing this number of batches"
        periodically. We save checkpoint to exp-dir/ whenever
        params.batch_idx_train % save_every_n == 0. The checkpoint filename
        has the form: f'exp-dir/checkpoint-{params.batch_idx_train}.pt'
        Note: It also saves checkpoint to `exp-dir/epoch-xxx.pt` at the
        end of each epoch where `xxx` is the epoch number counting from 1.
        """,
    )

    parser.add_argument(
        "--keep-last-k",
        type=int,
        default=30,
        help="""Only keep this number of checkpoints on disk.
        For instance, if it is 3, there are only 3 checkpoints
        in the exp-dir with filenames `checkpoint-xxx.pt`.
        It does not affect checkpoints with name `epoch-xxx.pt`.
        """,
    )

    parser.add_argument(
        "--average-period",
        type=int,
        default=200,
        help="""Update the averaged model, namely `model_avg`, after processing
        this number of batches. `model_avg` is a separate version of model,
        in which each floating-point parameter is the average of all the
        parameters from the start of training. Each time we take the average,
        we do: `model_avg = model * (average_period / batch_idx_train) +
            model_avg * ((batch_idx_train - average_period) / batch_idx_train)`.
        """,
    )

    parser.add_argument(
        "--use-fp16",
        type=str2bool,
        default=False,
        help="Whether to use half precision training.",
    )

    parser.add_argument(
        "--use-bf16",
        type=str2bool,
        default=False,
        help="Whether to use bf16 in AMP.",
    )

    add_finetune_arguments(parser)
    add_model_arguments(parser)

    return parser


def get_params() -> AttributeDict:
    """Return a dict containing training parameters.

    All training related parameters that are not passed from the commandline
    are saved in the variable `params`.

    Commandline options are merged into `params` after they are parsed, so
    you can also access them via `params`.

    Explanation of options saved in `params`:

        - best_train_loss: Best training loss so far. It is used to select
                           the model that has the lowest training loss. It is
                           updated during the training.

        - best_valid_loss: Best validation loss so far. It is used to select
                           the model that has the lowest validation loss. It is
                           updated during the training.

        - best_train_epoch: It is the epoch that has the best training loss.

        - best_valid_epoch: It is the epoch that has the best validation loss.

        - batch_idx_train: Used to writing statistics to tensorboard. It
                           contains number of batches trained so far across
                           epochs.

        - log_interval:  print training loss if batch_idx % log_interval` is 0

        - reset_interval: Reset statistics if batch_idx % reset_interval is 0

        - valid_interval:  Run validation if batch_idx % valid_interval is 0

        - feature_dim: The model input dim. It has to match the one used
                       in computing features.

        - subsampling_factor:  The subsampling factor for the model.

        - encoder_dim: Hidden dim for multi-head attention model.

        - num_decoder_layers: Number of decoder layer of transformer decoder.

        - warm_step: The warmup period that dictates the decay of the
              scale on "simple" (un-pruned) loss.
    """
    params = AttributeDict(
        {
            "best_train_loss": float("inf"),
            "best_valid_loss": float("inf"),
            "best_train_epoch": -1,
            "best_valid_epoch": -1,
            "batch_idx_train": 0,
            "log_interval": 50,
            "reset_interval": 200,
            "valid_interval": 3000,  # For the 100h subset, use 800
            # parameters for zipformer
            "feature_dim": 80,
            "subsampling_factor": 4,  # not passed in, this is fixed.
            # parameters for attention-decoder
            "ignore_id": -1,
            "label_smoothing": 0.1,
            "warm_step": 2000,
            "env_info": get_env_info(),
        }
    )

    return params


def _to_int_tuple(s: str):
    return tuple(map(int, s.split(",")))


def get_encoder_embed(params: AttributeDict) -> nn.Module:
    # encoder_embed converts the input of shape (N, T, num_features)
    # to the shape (N, (T - 7) // 2, encoder_dims).
    # That is, it does two things simultaneously:
    #   (1) subsampling: T -> (T - 7) // 2
    #   (2) embedding: num_features -> encoder_dims
    # In the normal configuration, we will downsample once more at the end
    # by a factor of 2, and most of the encoder stacks will run at a lower
    # sampling rate.
    encoder_embed = Conv2dSubsampling(
        in_channels=params.feature_dim,
        out_channels=_to_int_tuple(params.encoder_dim)[0],
        dropout=ScheduledFloat((0.0, 0.3), (20000.0, 0.1)),
    )
    return encoder_embed


def get_encoder_model(params: AttributeDict) -> nn.Module:
    encoder = Zipformer2(
        output_downsampling_factor=2,
        downsampling_factor=_to_int_tuple(params.downsampling_factor),
        num_encoder_layers=_to_int_tuple(params.num_encoder_layers),
        encoder_dim=_to_int_tuple(params.encoder_dim),
        encoder_unmasked_dim=_to_int_tuple(params.encoder_unmasked_dim),
        query_head_dim=_to_int_tuple(params.query_head_dim),
        pos_head_dim=_to_int_tuple(params.pos_head_dim),
        value_head_dim=_to_int_tuple(params.value_head_dim),
        pos_dim=params.pos_dim,
        num_heads=_to_int_tuple(params.num_heads),
        feedforward_dim=_to_int_tuple(params.feedforward_dim),
        cnn_module_kernel=_to_int_tuple(params.cnn_module_kernel),
        dropout=ScheduledFloat((0.0, 0.3), (20000.0, 0.1)),
        warmup_batches=4000.0,
        causal=params.causal,
        chunk_size=_to_int_tuple(params.chunk_size),
        left_context_frames=_to_int_tuple(params.left_context_frames),
    )
    return encoder


def get_decoder_model(params: AttributeDict) -> nn.Module:
    decoder = Decoder(
        vocab_size=params.vocab_size,
        decoder_dim=params.decoder_dim,
        blank_id=params.blank_id,
        context_size=params.context_size,
    )
    return decoder


def get_joiner_model(params: AttributeDict) -> nn.Module:
    joiner = Joiner(
        encoder_dim=max(_to_int_tuple(params.encoder_dim)),
        decoder_dim=params.decoder_dim,
        joiner_dim=params.joiner_dim,
        vocab_size=params.vocab_size,
    )
    return joiner


def get_attention_decoder_model(params: AttributeDict) -> nn.Module:
    decoder = AttentionDecoderModel(
        vocab_size=params.vocab_size,
        decoder_dim=params.attention_decoder_dim,
        num_decoder_layers=params.attention_decoder_num_layers,
        attention_dim=params.attention_decoder_attention_dim,
        num_heads=params.attention_decoder_num_heads,
        feedforward_dim=params.attention_decoder_feedforward_dim,
        memory_dim=max(_to_int_tuple(params.encoder_dim)),
        sos_id=params.sos_id,
        eos_id=params.eos_id,
        ignore_id=params.ignore_id,
        label_smoothing=params.label_smoothing,
    )
    return decoder


def get_model(params: AttributeDict) -> nn.Module:
    assert params.use_transducer or params.use_ctc, (
        f"At least one of them should be True, "
        f"but got params.use_transducer={params.use_transducer}, "
        f"params.use_ctc={params.use_ctc}"
    )

    encoder_embed = get_encoder_embed(params)
    encoder = get_encoder_model(params)

    if params.use_transducer:
        decoder = get_decoder_model(params)
        joiner = get_joiner_model(params)
    else:
        decoder = None
        joiner = None

    if params.use_attention_decoder:
        attention_decoder = get_attention_decoder_model(params)
    else:
        attention_decoder = None

    model = AsrModel(
        encoder_embed=encoder_embed,
        encoder=encoder,
        decoder=decoder,
        joiner=joiner,
        attention_decoder=attention_decoder,
        encoder_dim=max(_to_int_tuple(params.encoder_dim)),
        decoder_dim=params.decoder_dim,
        vocab_size=params.vocab_size,
        use_transducer=params.use_transducer,
        use_ctc=params.use_ctc,
        use_attention_decoder=params.use_attention_decoder,
    )
    return model


def get_spec_augment(params: AttributeDict) -> SpecAugment:
    num_frame_masks = int(10 * params.time_mask_ratio)
    max_frames_mask_fraction = 0.15 * params.time_mask_ratio
    logging.info(
        f"num_frame_masks: {num_frame_masks}, "
        f"max_frames_mask_fraction: {max_frames_mask_fraction}"
    )
    spec_augment = SpecAugment(
        time_warp_factor=0,  # Do time warping in model.py
        num_frame_masks=num_frame_masks,  # default: 10
        features_mask_size=27,
        num_feature_masks=2,
        frames_mask_size=100,
        max_frames_mask_fraction=max_frames_mask_fraction,  # default: 0.15
    )
    return spec_augment


def load_checkpoint_if_available(
    params: AttributeDict,
    model: nn.Module,
    model_avg: nn.Module = None,
    optimizer: Optional[torch.optim.Optimizer] = None,
    scheduler: Optional[LRSchedulerType] = None,
) -> Optional[Dict[str, Any]]:
    """Load checkpoint from file.

    If params.start_batch is positive, it will load the checkpoint from
    `params.exp_dir/checkpoint-{params.start_batch}.pt`. Otherwise, if
    params.start_epoch is larger than 1, it will load the checkpoint from
    `params.start_epoch - 1`.

    Apart from loading state dict for `model` and `optimizer` it also updates
    `best_train_epoch`, `best_train_loss`, `best_valid_epoch`,
    and `best_valid_loss` in `params`.

    Args:
      params:
        The return value of :func:`get_params`.
      model:
        The training model.
      model_avg:
        The stored model averaged from the start of training.
      optimizer:
        The optimizer that we are using.
      scheduler:
        The scheduler that we are using.
    Returns:
      Return a dict containing previously saved training info.
    """
    if params.start_batch > 0:
        filename = params.exp_dir / f"checkpoint-{params.start_batch}.pt"
    elif params.start_epoch > 1:
        filename = params.exp_dir / f"epoch-{params.start_epoch-1}.pt"
    else:
        return None

    assert filename.is_file(), f"{filename} does not exist!"

    saved_params = load_checkpoint(
        filename,
        model=model,
        model_avg=model_avg,
        optimizer=optimizer,
        scheduler=scheduler,
    )

    keys = [
        "best_train_epoch",
        "best_valid_epoch",
        "batch_idx_train",
        "best_train_loss",
        "best_valid_loss",
    ]
    for k in keys:
        params[k] = saved_params[k]

    if params.start_batch > 0:
        if "cur_epoch" in saved_params:
            params["start_epoch"] = saved_params["cur_epoch"]

    return saved_params


def save_checkpoint(
    params: AttributeDict,
    model: Union[nn.Module, DDP],
    model_avg: Optional[nn.Module] = None,
    optimizer: Optional[torch.optim.Optimizer] = None,
    scheduler: Optional[LRSchedulerType] = None,
    sampler: Optional[CutSampler] = None,
    scaler: Optional["GradScaler"] = None,
    rank: int = 0,
) -> None:
    """Save model, optimizer, scheduler and training stats to file.

    Args:
      params:
        It is returned by :func:`get_params`.
      model:
        The training model.
      model_avg:
        The stored model averaged from the start of training.
      optimizer:
        The optimizer used in the training.
      sampler:
       The sampler for the training dataset.
      scaler:
        The scaler used for mix precision training.
    """
    if rank != 0:
        return
    filename = params.exp_dir / f"epoch-{params.cur_epoch}.pt"
    save_checkpoint_impl(
        filename=filename,
        model=model,
        model_avg=model_avg,
        params=params,
        optimizer=optimizer,
        scheduler=scheduler,
        sampler=sampler,
        scaler=scaler,
        rank=rank,
    )

    if params.best_train_epoch == params.cur_epoch:
        best_train_filename = params.exp_dir / "best-train-loss.pt"
        copyfile(src=filename, dst=best_train_filename)

    if params.best_valid_epoch == params.cur_epoch:
        best_valid_filename = params.exp_dir / "best-valid-loss.pt"
        copyfile(src=filename, dst=best_valid_filename)


def compute_loss(
    params: AttributeDict,
    model: Union[nn.Module, DDP],
    sp: spm.SentencePieceProcessor,
    batch: dict,
    is_training: bool,
    spec_augment: Optional[SpecAugment] = None,
) -> Tuple[Tensor, MetricsTracker]:
    """
    Compute loss given the model and its inputs.

    Args:
      params:
        Parameters for training. See :func:`get_params`.
      model:
        The model for training. It is an instance of Zipformer in our case.
      batch:
        A batch of data. See `lhotse.dataset.K2SpeechRecognitionDataset()`
        for the content in it.
      is_training:
        True for training. False for validation. When it is True, this
        function enables autograd during computation; when it is False, it
        disables autograd.
     warmup: a floating point value which increases throughout training;
        values >= 1.0 are fully warmed up and have all modules present.
    """
    device = model.device if isinstance(model, DDP) else next(model.parameters()).device
    # breakpoint()
    feature = batch["inputs"]
    # at entry, feature is (N, T, C)
    assert feature.ndim == 3
    feature = feature.to(device)

    supervisions = batch["supervisions"]
    feature_lens = supervisions["num_frames"].to(device)

    batch_idx_train = params.batch_idx_train
    warm_step = params.warm_step

    texts = batch["supervisions"]["text"]
    y = sp.encode(texts, out_type=int)
    # breakpoint()
    y = k2.RaggedTensor(y)

    use_cr_ctc = params.use_cr_ctc
    use_spec_aug = use_cr_ctc and is_training
    if use_spec_aug:
        supervision_intervals = batch["supervisions"]
        supervision_segments = torch.stack(
            [
                supervision_intervals["sequence_idx"],
                supervision_intervals["start_frame"],
                supervision_intervals["num_frames"],
            ],
            dim=1,
        )  # shape: (S, 3)
    else:
        supervision_segments = None

    with torch.set_grad_enabled(is_training):
        simple_loss, pruned_loss, ctc_loss, attention_decoder_loss, cr_loss = model(
            x=feature,
            x_lens=feature_lens,
            y=y,
            prune_range=params.prune_range,
            am_scale=params.am_scale,
            lm_scale=params.lm_scale,
            use_cr_ctc=use_cr_ctc,
            use_spec_aug=use_spec_aug,
            spec_augment=spec_augment,
            supervision_segments=supervision_segments,
            time_warp_factor=params.spec_aug_time_warp_factor,
        )

        loss = 0.0

        if params.use_transducer:
            s = params.simple_loss_scale
            # take down the scale on the simple loss from 1.0 at the start
            # to params.simple_loss scale by warm_step.
            simple_loss_scale = (
                s
                if batch_idx_train >= warm_step
                else 1.0 - (batch_idx_train / warm_step) * (1.0 - s)
            )
            pruned_loss_scale = (
                1.0
                if batch_idx_train >= warm_step
                else 0.1 + 0.9 * (batch_idx_train / warm_step)
            )
            loss += simple_loss_scale * simple_loss + pruned_loss_scale * pruned_loss

        if params.use_ctc:
            loss += params.ctc_loss_scale * ctc_loss
            if use_cr_ctc:
                loss += params.cr_loss_scale * cr_loss

        if params.use_attention_decoder:
            loss += params.attention_decoder_loss_scale * attention_decoder_loss

    assert loss.requires_grad == is_training

    info = MetricsTracker()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        info["frames"] = (feature_lens // params.subsampling_factor).sum().item()

    # Note: We use reduction=sum while computing the loss.
    info["loss"] = loss.detach().cpu().item()
    if params.use_transducer:
        info["simple_loss"] = simple_loss.detach().cpu().item()
        info["pruned_loss"] = pruned_loss.detach().cpu().item()
    if params.use_ctc:
        info["ctc_loss"] = ctc_loss.detach().cpu().item()
        if params.use_cr_ctc:
            info["cr_loss"] = cr_loss.detach().cpu().item()
    if params.use_attention_decoder:
        info["attn_decoder_loss"] = attention_decoder_loss.detach().cpu().item()

    return loss, info


def compute_validation_loss(
    params: AttributeDict,
    model: Union[nn.Module, DDP],
    sp: spm.SentencePieceProcessor,
    valid_dl: torch.utils.data.DataLoader,
    world_size: int = 1,
) -> MetricsTracker:
    """Run the validation process."""
    model.eval()

    tot_loss = MetricsTracker()

    for batch_idx, batch in enumerate(valid_dl):
        loss, loss_info = compute_loss(
            params=params,
            model=model,
            sp=sp,
            batch=batch,
            is_training=False,
        )
        assert loss.requires_grad is False
        tot_loss = tot_loss + loss_info

    if world_size > 1:
        tot_loss.reduce(loss.device)

    loss_value = tot_loss["loss"] / tot_loss["frames"]
    if loss_value < params.best_valid_loss:
        params.best_valid_epoch = params.cur_epoch
        params.best_valid_loss = loss_value

    return tot_loss


def train_one_epoch(
    params: AttributeDict,
    model: Union[nn.Module, DDP],
    optimizer: torch.optim.Optimizer,
    scheduler: LRSchedulerType,
    sp: spm.SentencePieceProcessor,
    train_dl: torch.utils.data.DataLoader,
    test_dl: torch.utils.data.DataLoader,
    scaler: "GradScaler",
    spec_augment: Optional[SpecAugment] = None,
    model_avg: Optional[nn.Module] = None,
    tb_writer: Optional[SummaryWriter] = None,
    world_size: int = 1,
    rank: int = 0,
) -> None:
    """Train the model for one epoch.

    The training loss from the mean of all frames is saved in
    `params.train_loss`. It runs the validation process every
    `params.valid_interval` batches.

    Args:
      params:
        It is returned by :func:`get_params`.
      model:
        The model for training.
      optimizer:
        The optimizer we are using.
      scheduler:
        The learning rate scheduler, we call step() every step.
      train_dl:
        Dataloader for the training dataset.
      valid_dl:
        Dataloader for the validation dataset.
      scaler:
        The scaler used for mix precision training.
      spec_augment:
        The SpecAugment instance used only when use_cr_ctc is True.
      model_avg:
        The stored model averaged from the start of training.
      tb_writer:
        Writer to write log messages to tensorboard.
      world_size:
        Number of nodes in DDP training. If it is 1, DDP is disabled.
      rank:
        The rank of the node in DDP training. If no DDP is used, it should
        be set to 0.
    """
    model.train()

    tot_loss = MetricsTracker()

    saved_bad_model = False

    def save_bad_model(suffix: str = ""):
        save_checkpoint_impl(
            filename=params.exp_dir / f"bad-model{suffix}-{rank}.pt",
            model=model,
            model_avg=model_avg,
            params=params,
            optimizer=optimizer,
            scheduler=scheduler,
            sampler=train_dl.sampler,
            scaler=scaler,
            rank=0,
        )

    tot_time = tot_frames = 0.0
    tot_padding_ratio = 0.0

    for batch_idx, batch in enumerate(train_dl):
    # batch = next(iter(train_dl))
    # for batch_idx in range(0,3000):
        # pprint(batch, depth=3)

        # torch.cuda.synchronize() 
        # begin = time.perf_counter()
        if batch_idx == 0:
            torch.cuda.synchronize(device=rank) 
            start_time = time.perf_counter()
            begin = start_time
        if batch_idx % 10 == 0:
            set_batch_count(model, get_adjusted_batch_count(params))

        params.batch_idx_train += 1
        batch_size = len(batch["supervisions"]["text"])
        actual_frames = batch["supervisions"]["num_frames"]
        total_frames = batch_size * torch.max(actual_frames).item()
        current_batch_total_frames = torch.sum(actual_frames).item()

        tot_padding_ratio += 1 - current_batch_total_frames / total_frames
        
        tot_frames += current_batch_total_frames

        try:
            with torch_autocast(enabled=params.use_autocast, dtype=params.dtype):
                loss, loss_info = compute_loss(
                    params=params,
                    model=model,
                    sp=sp,
                    batch=batch,
                    is_training=True,
                    spec_augment=spec_augment,
                )

            # summary stats
            tot_loss = (tot_loss * (1 - 1 / params.reset_interval)) + loss_info

            # NOTE: We use reduction==sum and loss is computed over utterances
            # in the batch and there is no normalization to it so far.
            scaler.scale(loss).backward()
            scheduler.step_batch(params.batch_idx_train)

            scaler.step(optimizer)
            scaler.update()
            optimizer.zero_grad()
            

        except Exception as e:
            logging.info(f"Caught exception: {e}.")
            save_bad_model()
            display_and_save_batch(batch, params=params, sp=sp)
            raise

        '''
        torch.cuda.synchronize() 
        end = time.perf_counter()
        elapsed_time = end - begin
        begin = end
        # 提取当前 Batch 中所有音频的 ID 和长度
        cut_info = [
            {'id': cut.id, "duration": cut.duration, "num_frames": batch['supervisions']['num_frames'][idx].item(), "text": smart_byte_decode(batch['supervisions']['text'][idx])}
            for idx, cut in enumerate(batch['supervisions']['cut']) # 或者根据你 dataloader 的具体返回格式
        ]
        
        # 保存为更轻量的 JSON，方便离线分析原因
        with open(f"batch_{batch_idx}.json", "w", encoding='utf-8') as f:
            json.dump({"elapsed": elapsed_time, "cuts": cut_info}, f, indent=4, ensure_ascii=False)
        '''
        
        if params.print_diagnostics and batch_idx == 5:
            return

        if (
            rank == 0
            and params.batch_idx_train > 0
            and params.batch_idx_train % params.average_period == 0
        ):
            update_averaged_model(
                params=params,
                model_cur=model,
                model_avg=model_avg,
            )

        if (
            params.batch_idx_train > 0
            and params.batch_idx_train % params.save_every_n == 0
        ):
            save_checkpoint_with_global_batch_idx(
                out_dir=params.exp_dir,
                global_batch_idx=params.batch_idx_train,
                model=model,
                model_avg=model_avg,
                params=params,
                optimizer=optimizer,
                scheduler=scheduler,
                sampler=train_dl.sampler,
                scaler=scaler,
                rank=rank,
            )
            remove_checkpoints(
                out_dir=params.exp_dir,
                topk=params.keep_last_k,
                rank=rank,
            )

        if params.use_autocast:
            cur_grad_scale = scaler._scale.item()

            if cur_grad_scale < 0.01:
                if not saved_bad_model:
                    save_bad_model(suffix="-first-warning")
                    saved_bad_model = True
                    if not params.inf_check:
                        register_inf_check_hooks(model)
                logging.warning(f"Grad scale is small: {cur_grad_scale}")

            if cur_grad_scale < 1.0e-05:
                save_bad_model()
                raise_grad_scale_is_too_small_error(cur_grad_scale)

            # If the grad scale was less than 1, try increasing it.    The _growth_interval
            # of the grad scaler is configurable, but we can't configure it to have different
            # behavior depending on the current grad scale.
            if (
                batch_idx % 25 == 0
                and cur_grad_scale < 2.0
                or batch_idx % 100 == 0
                and cur_grad_scale < 8.0
                or batch_idx % 400 == 0
                and cur_grad_scale < 32.0
            ):
                scaler.update(cur_grad_scale * 2.0)

        if batch_idx % params.log_interval == 0:
            cur_lr = max(scheduler.get_last_lr())
            cur_grad_scale = scaler._scale.item() if params.use_autocast else 1.0

            logging.info(
                f"Epoch {params.cur_epoch}, "
                f"batch {batch_idx}, loss[{loss_info}], "
                f"tot_loss[{tot_loss}], batch size: {batch_size}, "
                f"lr: {cur_lr:.2e}, "
                + (f"grad_scale: {scaler._scale.item()}" if params.use_autocast else "")
            )

            if tb_writer is not None:
                tb_writer.add_scalar(
                    "train/learning_rate", cur_lr, params.batch_idx_train
                )

                padding_ratio = tot_padding_ratio / params.log_interval
                tot_padding_ratio = 0.0
                tb_writer.add_scalar(
                    "train/padding_ratio", padding_ratio, params.batch_idx_train
                )

                if batch_idx % 1000 == 0:
                    torch.cuda.synchronize(device=rank) 
                    end_time = time.perf_counter()
                    tot_time = end_time - start_time
                    fps = tot_frames / tot_time
                    tb_writer.add_scalar(
                        "train/fps", fps, params.batch_idx_train
                    )

                loss_info.write_summary(
                    tb_writer, "train/current_", params.batch_idx_train
                )
                tot_loss.write_summary(tb_writer, "train/tot_", params.batch_idx_train)
                if params.use_autocast:
                    tb_writer.add_scalar(
                        "train/grad_scale", cur_grad_scale, params.batch_idx_train
                    )
        # print(batch_idx)
        if 0 and batch_idx % params.valid_interval == 0 and not params.print_diagnostics:
            logging.info("Computing validation loss")
            # breakpoint()
            valid_info = compute_validation_loss(
                params=params,
                model=model,
                sp=sp,
                valid_dl=test_dl,
                world_size=world_size,
            )
            model.train()
            logging.info(f"Epoch {params.cur_epoch}, validation: {valid_info}")
            logging.info(
                f"Maximum memory allocated so far is {torch.cuda.max_memory_allocated()//1000000}MB"
            )
            if tb_writer is not None:
                valid_info.write_summary(
                    tb_writer, "train/valid_", params.batch_idx_train
                )
            # logging.info("Loading testing model!")
            # test_model = get_model(params)
            # test_model.eval()

            # logging.info("Computing wer on test sets!")
            # start = batch_idx - 4000 * 4
            # if start <= 0:
            #     start = 4000
            # filenames = []
            # for i in range(start, batch_idx + 1, 4000):
            #     filenames.append(f"{params.exp_dir}/checkpoint-{i}.pt")

            # if batch_idx == params.valid_interval:
            #     logging.info(f"Loading checkpoint-{batch_idx}.pt")
            #     load_checkpoint(f"{params.exp_dir}/checkpoint-{params.valid_interval}.pt", test_model)
            # else:
            #     logging.info(f"averaging checkpoints {filenames}...")
            #     test_model.load_state_dict(average_checkpoints(filenames, device=0))
            # for test_set, test_dl in zip(test_sets, test_dl):
            #     logging.info(f"Start decoding test set: {test_set}")

            #     results_dict = decode_dataset(
            #         dl=test_dl,
            #         params=params,
            #         model=test_model,
            #         sp=sp,
            #         word_table=None,
            #         decoding_graph=None,
            #     )

            #     wer = save_results(
            #         params=params,
            #         test_set_name=test_set,
            #         results_dict=results_dict,
            #     )

            #     tb_writer.add_scalar(
            #             f"{test_set}", wer, params.batch_idx_train
            #         )
            

    loss_value = tot_loss["loss"] / tot_loss["frames"]
    params.train_loss = loss_value
    if params.train_loss < params.best_train_loss:
        params.best_train_epoch = params.cur_epoch
        params.best_train_loss = params.train_loss

def post_processing(
    results: List[Tuple[str, List[str], List[str]]],
) -> List[Tuple[str, List[str], List[str]]]:
    new_results = []
    for key, ref, hyp in results:
        new_ref = asr_text_post_processing(" ".join(ref)).split()
        new_hyp = asr_text_post_processing(" ".join(hyp)).split()
        new_results.append((key, new_ref, new_hyp))
    return new_results


def decode_one_batch(
    params: AttributeDict,
    model: nn.Module,
    sp: spm.SentencePieceProcessor,
    batch: dict,
    word_table: Optional[k2.SymbolTable] = None,
    decoding_graph: Optional[k2.Fsa] = None,
) -> Dict[str, List[List[str]]]:
    """Decode one batch and return the result in a dict. The dict has the
    following format:

        - key: It indicates the setting used for decoding. For example,
               if greedy_search is used, it would be "greedy_search"
               If beam search with a beam size of 7 is used, it would be
               "beam_7"
        - value: It contains the decoding result. `len(value)` equals to
                 batch size. `value[i]` is the decoding result for the i-th
                 utterance in the given batch.
    Args:
      params:
        It's the return value of :func:`get_params`.
      model:
        The neural model.
      sp:
        The BPE model.
      batch:
        It is the return value from iterating
        `lhotse.dataset.K2SpeechRecognitionDataset`. See its documentation
        for the format of the `batch`.
      word_table:
        The word symbol table.
      decoding_graph:
        The decoding graph. Can be either a `k2.trivial_graph` or HLG, Used
        only when --decoding_method is fast_beam_search, fast_beam_search_nbest,
        fast_beam_search_nbest_oracle, and fast_beam_search_nbest_LG.
    Returns:
      Return the decoding result. See above description for the format of
      the returned dict.
    """
    device = next(model.parameters()).device
    feature = batch["inputs"]
    assert feature.ndim == 3

    feature = feature.to(device)
    # at entry, feature is (N, T, C)

    supervisions = batch["supervisions"]
    feature_lens = supervisions["num_frames"].to(device)

    if params.causal:
        # this seems to cause insertions at the end of the utterance if used with zipformer.
        pad_len = 30
        feature_lens += pad_len
        feature = torch.nn.functional.pad(
            feature,
            pad=(0, 0, 0, pad_len),
            value=LOG_EPS,
        )

    encoder_out, encoder_out_lens = model.forward_encoder(feature, feature_lens)

    hyps = []

    if params.decoding_method == "fast_beam_search":
        hyp_tokens = fast_beam_search_one_best(
            model=model,
            decoding_graph=decoding_graph,
            encoder_out=encoder_out,
            encoder_out_lens=encoder_out_lens,
            beam=params.beam,
            max_contexts=params.max_contexts,
            max_states=params.max_states,
        )
        for hyp in sp.decode(hyp_tokens):
            hyps.append(smart_byte_decode(hyp).split())
    elif params.decoding_method == "fast_beam_search_nbest_LG":
        hyp_tokens = fast_beam_search_nbest_LG(
            model=model,
            decoding_graph=decoding_graph,
            encoder_out=encoder_out,
            encoder_out_lens=encoder_out_lens,
            beam=params.beam,
            max_contexts=params.max_contexts,
            max_states=params.max_states,
            num_paths=params.num_paths,
            nbest_scale=params.nbest_scale,
        )
        for hyp in hyp_tokens:
            hyps.append([word_table[i] for i in hyp])
    elif params.decoding_method == "fast_beam_search_nbest":
        hyp_tokens = fast_beam_search_nbest(
            model=model,
            decoding_graph=decoding_graph,
            encoder_out=encoder_out,
            encoder_out_lens=encoder_out_lens,
            beam=params.beam,
            max_contexts=params.max_contexts,
            max_states=params.max_states,
            num_paths=params.num_paths,
            nbest_scale=params.nbest_scale,
        )
        for hyp in sp.decode(hyp_tokens):
            hyps.append(smart_byte_decode(hyp).split())
    elif params.decoding_method == "fast_beam_search_nbest_oracle":
        hyp_tokens = fast_beam_search_nbest_oracle(
            model=model,
            decoding_graph=decoding_graph,
            encoder_out=encoder_out,
            encoder_out_lens=encoder_out_lens,
            beam=params.beam,
            max_contexts=params.max_contexts,
            max_states=params.max_states,
            num_paths=params.num_paths,
            ref_texts=sp.encode(
                byte_encode(tokenize_by_CJK_char(supervisions["text"]))
            ),
            nbest_scale=params.nbest_scale,
        )
        for hyp in sp.decode(hyp_tokens):
            hyps.append(smart_byte_decode(hyp).split())
    elif params.decoding_method == "greedy_search" and params.max_sym_per_frame == 1:
        hyp_tokens = greedy_search_batch(
            model=model,
            encoder_out=encoder_out,
            encoder_out_lens=encoder_out_lens,
            blank_penalty=params.blank_penalty,
        )
        # breakpoint()
        for hyp in sp.decode(hyp_tokens):
            hyps.append(hyp.split())
            # hyps.append(smart_byte_decode(hyp).split())
    elif params.decoding_method == "modified_beam_search":
        hyp_tokens = modified_beam_search(
            model=model,
            encoder_out=encoder_out,
            encoder_out_lens=encoder_out_lens,
            beam=params.beam_size,
        )
        for hyp in sp.decode(hyp_tokens):
            hyps.append(smart_byte_decode(hyp).split())
    else:
        batch_size = encoder_out.size(0)

        for i in range(batch_size):
            # fmt: off
            encoder_out_i = encoder_out[i:i+1, :encoder_out_lens[i]]
            # fmt: on
            if params.decoding_method == "greedy_search":
                hyp = greedy_search(
                    model=model,
                    encoder_out=encoder_out_i,
                    max_sym_per_frame=params.max_sym_per_frame,
                )
            elif params.decoding_method == "beam_search":
                hyp = beam_search(
                    model=model,
                    encoder_out=encoder_out_i,
                    beam=params.beam_size,
                )
            else:
                raise ValueError(
                    f"Unsupported decoding method: {params.decoding_method}"
                )
            hyps.append(smart_byte_decode(sp.decode(hyp)).split())
    if params.decoding_method == "greedy_search":
        return {"greedy_search": hyps}
    elif "fast_beam_search" in params.decoding_method:
        key = f"beam_{params.beam}_"
        key += f"max_contexts_{params.max_contexts}_"
        key += f"max_states_{params.max_states}"
        if "nbest" in params.decoding_method:
            key += f"_num_paths_{params.num_paths}_"
            key += f"nbest_scale_{params.nbest_scale}"
            if "LG" in params.decoding_method:
                key += f"_ngram_lm_scale_{params.ngram_lm_scale}"

        return {key: hyps}
    else:
        return {f"beam_size_{params.beam_size}": hyps}


def decode_dataset(
    dl: torch.utils.data.DataLoader,
    params: AttributeDict,
    model: nn.Module,
    sp: spm.SentencePieceProcessor,
    word_table: Optional[k2.SymbolTable] = None,
    decoding_graph: Optional[k2.Fsa] = None,
) -> Dict[str, List[Tuple[str, List[str], List[str]]]]:
    """Decode dataset.

    Args:
      dl:
        PyTorch's dataloader containing the dataset to decode.
      params:
        It is returned by :func:`get_params`.
      model:
        The neural model.
      sp:
        The BPE model.
      word_table:
        The word symbol table.
      decoding_graph:
        The decoding graph. Can be either a `k2.trivial_graph` or HLG, Used
        only when --decoding_method is fast_beam_search, fast_beam_search_nbest,
        fast_beam_search_nbest_oracle, and fast_beam_search_nbest_LG.
    Returns:
      Return a dict, whose key may be "greedy_search" if greedy search
      is used, or it may be "beam_7" if beam size of 7 is used.
      Its value is a list of tuples. Each tuple contains two elements:
      The first is the reference transcript, and the second is the
      predicted result.
    """
    num_cuts = 0

    try:
        num_batches = len(dl)
    except TypeError:
        num_batches = "?"

    if params.decoding_method == "greedy_search":
        log_interval = 50
    else:
        log_interval = 20

    results = defaultdict(list)
    for batch_idx, batch in enumerate(dl):
        texts = batch["supervisions"]["text"]
        texts = [tokenize_by_CJK_char(str(text)).split() for text in texts]
        # print(texts)
        # exit()
        cut_ids = [cut.id for cut in batch["supervisions"]["cut"]]

        hyps_dict = decode_one_batch(
            params=params,
            model=model,
            sp=sp,
            decoding_graph=decoding_graph,
            word_table=word_table,
            batch=batch,
        )

        for name, hyps in hyps_dict.items():
            this_batch = []
            assert len(hyps) == len(texts)
            for cut_id, hyp_words, ref_text in zip(cut_ids, hyps, texts):
                this_batch.append((cut_id, ref_text, hyp_words))

            results[name].extend(this_batch)

        num_cuts += len(texts)

        if batch_idx % log_interval == 0:
            batch_str = f"{batch_idx}/{num_batches}"

            logging.info(f"batch {batch_str}, cuts processed until now is {num_cuts}")
    return results

def save_results(
    params: AttributeDict,
    test_set_name: str,
    results_dict: Dict[str, List[Tuple[str, List[str], List[str]]]],
):
    test_set_wers = dict()
    for key, results in results_dict.items():
        recog_path = (
            params.res_dir / f"recogs-{test_set_name}-{key}-{params.suffix}.txt"
        )
        results = post_processing(results)
        results = sorted(results)
        # store_transcripts(filename=recog_path, texts=results)
        # logging.info(f"The transcripts are stored in {recog_path}")

        # The following prints out WERs, per-word error statistics and aligned
        # ref/hyp pairs.
        errs_filename = (
            params.res_dir / f"errs-{test_set_name}-{key}-{params.suffix}.txt"
        )
        with open(errs_filename, "w") as f:
            wer = write_error_stats(
                f, f"{test_set_name}-{key}", results, enable_log=True
            )
            test_set_wers[key] = wer
        return wer



def run(rank, world_size, args):
    """
    Args:
      rank:
        It is a value between 0 and `world_size-1`, which is
        passed automatically by `mp.spawn()` in :func:`main`.
        The node with rank 0 is responsible for saving checkpoint.
      world_size:
        Number of GPUs for DDP training.
      args:
        The return value of get_parser().parse_args()
    """
    params = get_params()
    params.update(vars(args))
    params.do_finetune = params.do_finetune or bool(params.finetune_ckpt)

    fix_random_seed(params.seed)
    if world_size > 1:
        setup_dist(rank, world_size, params.master_port)

    setup_logger(f"{params.exp_dir}/log/log-train")
    logging.info("Training started")
    if params.do_finetune:
        logging.info("Fine-tune initialization is enabled")

    if args.tensorboard and rank == 0:
        tb_writer = SummaryWriter(log_dir=f"{params.exp_dir}/tensorboard")
    else:
        tb_writer = None

    wandb_run = None
    if rank == 0 and params.use_wandb:
        if wandb is None:
            raise ImportError(
                "wandb is not installed. Please install it or set --use-wandb False."
            )
        wandb_kwargs = {
            "project": params.wandb_project,
            "config": sanitize_for_wandb(dict(params)),
            "sync_tensorboard": True,
        }
        if params.wandb_name:
            wandb_kwargs["name"] = params.wandb_name
        if params.wandb_group:
            wandb_kwargs["group"] = params.wandb_group
        if params.wandb_dir:
            wandb_kwargs["dir"] = params.wandb_dir
        wandb_run = wandb.init(**wandb_kwargs)

    device = torch.device("cpu")
    if torch.cuda.is_available():
        device = torch.device("cuda", rank)
    logging.info(f"Device: {device}")

    sp = spm.SentencePieceProcessor()
    sp.load(params.bpe_model)

    # <blk> is defined in local/train_bpe_model.py
    params.blank_id = sp.piece_to_id("<blk>")
    params.sos_id = params.eos_id = sp.piece_to_id("<sos/eos>")
    params.vocab_size = sp.get_piece_size()

    if not params.use_transducer:
        if not params.use_attention_decoder:
            params.ctc_loss_scale = 1.0
        else:
            assert params.ctc_loss_scale + params.attention_decoder_loss_scale == 1.0, (
                params.ctc_loss_scale,
                params.attention_decoder_loss_scale,
            )

    if params.use_bf16:  # amp + bf16
        assert torch.cuda.is_bf16_supported(), "Your GPU does not support bf16!"
        assert not params.use_fp16, "You can only use either fp16 or bf16"
        params.dtype = torch.bfloat16
        params.use_autocast = True
    elif params.use_fp16:  # amp + fp16
        params.dtype = torch.float16
        params.use_autocast = True
    else:  # fp32
        params.dtype = torch.float32
        params.use_autocast = False

    logging.info(f"Using dtype={params.dtype}")
    logging.info(f"Use AMP={params.use_autocast}")

    logging.info(params)

    logging.info("About to create model")
    model = get_model(params)

    num_param = sum([p.numel() for p in model.parameters()])
    logging.info(f"Number of model parameters: {num_param}")

    if params.use_cr_ctc:
        assert params.use_ctc
        assert not params.enable_spec_aug  # we will do spec_augment in model.py
        spec_augment = get_spec_augment(params)
    else:
        spec_augment = None

    assert params.save_every_n >= params.average_period
    model_avg: Optional[nn.Module] = None
    if rank == 0:
        # model_avg is only used with rank 0
        model_avg = copy.deepcopy(model).to(torch.float64)

    checkpoints = None
    if params.do_finetune and params.start_epoch == 1 and params.start_batch == 0:
        assert params.finetune_ckpt, "--finetune-ckpt is required for fine-tuning"
        init_modules = params.init_modules.split(",") if params.init_modules else None
        load_model_params_with_vocab_remap(
            model=model,
            ckpt=params.finetune_ckpt,
            old_bpe_model=params.old_bpe_model,
            new_bpe_model=params.bpe_model,
            init_modules=init_modules,
            state_source=params.finetune_state_src,
        )
        if rank == 0:
            model_avg = copy.deepcopy(model).to(torch.float64)
    else:
        assert params.start_epoch > 0, params.start_epoch
        checkpoints = load_checkpoint_if_available(
            params=params, model=model, model_avg=model_avg
        )

    model.to(device)
    if world_size > 1:
        logging.info("Using DDP")
        model = DDP(model, device_ids=[rank], find_unused_parameters=True)

    optimizer = ScaledAdam(
        get_parameter_groups_with_lrs(model, lr=params.base_lr, include_names=True),
        lr=params.base_lr,  # should have no effect
        clipping_scale=2.0,
    )

    scheduler = Eden(optimizer, params.lr_batches, params.lr_epochs)

    if checkpoints and "optimizer" in checkpoints:
        logging.info("Loading optimizer state dict")
        optimizer.load_state_dict(checkpoints["optimizer"])

    if (
        checkpoints
        and "scheduler" in checkpoints
        and checkpoints["scheduler"] is not None
    ):
        logging.info("Loading scheduler state dict")
        scheduler.load_state_dict(checkpoints["scheduler"])

    if params.print_diagnostics:
        opts = diagnostics.TensorDiagnosticOptions(
            512
        )  # allow 4 megabytes per sub-module
        diagnostic = diagnostics.attach_diagnostics(model, opts)

    if params.inf_check:
        register_inf_check_hooks(model)

    data_module = AsrDataModule(args)
    multi_dataset = MultiDataset(args)

    train_cuts = multi_dataset.train_cuts()

    def remove_short_and_long_utt(c: Cut):
        # Keep only utterances with duration between 1 second and 12 seconds
        #
        # Caution: There is a reason to select 12.0 here. Please see
        # ../local/display_manifest_statistics.py
        #
        # You should use ../local/display_manifest_statistics.py to get
        # an utterance duration distribution for your dataset to select
        # the threshold
        if c.duration < 0.5:
            # logging.warning(
            #     f"Exclude cut with ID {c.id} from training. Duration: {c.duration}"
            # )
            return False

        # In pruned RNN-T, we require that T >= S
        # where T is the number of feature frames after subsampling
        # and S is the number of tokens in the utterance

        # In ./zipformer.py, the conv module uses the following expression
        # for subsampling
        T = ((c.duration*100 - 7) // 2 + 1) // 2
        tokens = sp.encode(c.supervisions[0].text, out_type=str)

        if T < len(tokens):
            # logging.warning(
            #     f"Exclude cut with ID {c.id} from training. "
            #     f"Number of frames (before subsampling): {c.duration*100}. "
            #     f"Number of frames (after subsampling): {T}. "
            #     f"Text: {c.supervisions[0].text}. "
            #     f"Tokens: {tokens}. "
            #     f"Number of tokens: {len(tokens)}"
            # )
            return False

        # if c.supervisions[0].language == 'English':
        #     v = len(c.supervisions[0].text.split()) / c.duration
        #     if v > 1 and v < 8:
        #         return True
        #     else:
        #         # logging.warning(f"English: Too slow or fast! v: {v}, text:{c.supervisions[0].text}, time:{c.duration}")
        #         return False
        # else:
        #     v = len(c.supervisions[0].text) / c.duration
        #     if v > 1 and v < 9:
        #         return True
        #     else:
        #         # logging.warning(f"Chinese: Too slow or fast! v: {v}, text:{c.supervisions[0].text}, time:{c.duration}")
        #         return False
    
        return True

    def tokenize_and_encode_text(c: Cut):
        # Text normalize for each sample
        text = c.supervisions[0].text
        if args.byte_encode:
            text = byte_encode(tokenize_by_CJK_char(text))
        else:
            text = tokenize_by_CJK_char(text)
        c.supervisions[0].text = text
        return c
    
    train_cuts = train_cuts.filter(remove_short_and_long_utt)

    train_cuts = train_cuts.map(tokenize_and_encode_text)

    # if params.start_batch > 0 and checkpoints and "sampler" in checkpoints:
    #     # We only load the sampler's state dict when it loads a checkpoint
    #     # saved in the middle of an epoch
    #     sampler_state_dict = checkpoints["sampler"]
    # else:
    sampler_state_dict = None

    train_dl = data_module.train_dataloaders(
        train_cuts, 
        sampler_state_dict=sampler_state_dict,
        world_size=world_size,
        rank=rank,
    )

    def remove_short_utt(c: Cut):
        T = ((c.num_frames - 7) // 2 + 1) // 2
        if T <= 0:
            logging.warning(
                f"Excluding cut with ID: {c.id} from decoding, num_frames: {c.num_frames}"
            )
        return T > 0

    # test_sets_cuts = multi_dataset.test_cuts()

    # test_sets = test_sets_cuts.keys()
    # test_dl = [
    #     data_module.test_dataloaders(test_sets_cuts[cuts_name].filter(remove_short_utt))
    #     for cuts_name in test_sets
    # ]
    valid_cuts = multi_dataset.dev_cuts()
    valid_dl = data_module.valid_dataloaders(valid_cuts)


    # if not params.print_diagnostics:
    #     scan_pessimistic_batches_for_oom(
    #         model=model,
    #         train_dl=train_dl,
    #         optimizer=optimizer,
    #         sp=sp,
    #         params=params,
    #     )

    scaler = create_grad_scaler(enabled=params.use_autocast, init_scale=1.0)
    if checkpoints and "grad_scaler" in checkpoints:
        logging.info("Loading grad scaler state dict")
        scaler.load_state_dict(checkpoints["grad_scaler"])

    for epoch in range(params.start_epoch, params.num_epochs + 1):
        scheduler.step_epoch(epoch - 1)
        fix_random_seed(params.seed + epoch - 1)
        train_dl.sampler.set_epoch(epoch - 1)

        if tb_writer is not None:
            tb_writer.add_scalar("train/epoch", epoch, params.batch_idx_train)

        params.cur_epoch = epoch

        train_one_epoch(
            params=params,
            model=model,
            model_avg=model_avg,
            optimizer=optimizer,
            scheduler=scheduler,
            sp=sp,
            train_dl=train_dl,
            test_dl=valid_dl,
            scaler=scaler,
            spec_augment=spec_augment,
            tb_writer=tb_writer,
            world_size=world_size,
            rank=rank,
        )

        if params.print_diagnostics:
            diagnostic.print_diagnostics()
            break

        save_checkpoint(
            params=params,
            model=model,
            model_avg=model_avg,
            optimizer=optimizer,
            scheduler=scheduler,
            sampler=train_dl.sampler,
            scaler=scaler,
            rank=rank,
        )

    logging.info("Done!")

    if rank == 0 and wandb_run is not None:
        wandb.finish()

    if world_size > 1:
        torch.distributed.barrier()
        cleanup_dist()


def display_and_save_batch(
    batch: dict,
    params: AttributeDict,
    sp: spm.SentencePieceProcessor,
) -> None:
    """Display the batch statistics and save the batch into disk.

    Args:
      batch:
        A batch of data. See `lhotse.dataset.K2SpeechRecognitionDataset()`
        for the content in it.
      params:
        Parameters for training. See :func:`get_params`.
      sp:
        The BPE model.
    """
    from lhotse.utils import uuid4

    filename = f"{params.exp_dir}/batch-{uuid4()}.pt"
    logging.info(f"Saving batch to {filename}")
    torch.save(batch, filename)

    supervisions = batch["supervisions"]
    features = batch["inputs"]

    logging.info(f"features shape: {features.shape}")

    y = sp.encode(supervisions["text"], out_type=int)
    num_tokens = sum(len(i) for i in y)
    logging.info(f"num tokens: {num_tokens}")


def scan_pessimistic_batches_for_oom(
    model: Union[nn.Module, DDP],
    train_dl: torch.utils.data.DataLoader,
    optimizer: torch.optim.Optimizer,
    sp: spm.SentencePieceProcessor,
    params: AttributeDict,
    spec_augment: Optional[SpecAugment] = None,
):
    from lhotse.dataset import find_pessimistic_batches

    logging.info(
        "Sanity check -- see if any of the batches in epoch 1 would cause OOM."
    )
    batches, crit_values = find_pessimistic_batches(train_dl.sampler)
    for criterion, cuts in batches.items():
        batch = train_dl.dataset[cuts]
        try:
            with torch_autocast(enabled=params.use_autocast, dtype=params.dtype):
                loss, _ = compute_loss(
                    params=params,
                    model=model,
                    sp=sp,
                    batch=batch,
                    is_training=True,
                    spec_augment=spec_augment,
                )
            loss.backward()
            optimizer.zero_grad()
        except Exception as e:
            if "CUDA out of memory" in str(e):
                logging.error(
                    "Your GPU ran out of memory with the current "
                    "max_duration setting. We recommend decreasing "
                    "max_duration and trying again.\n"
                    f"Failing criterion: {criterion} "
                    f"(={crit_values[criterion]}) ..."
                )
            display_and_save_batch(batch, params=params, sp=sp)
            raise
        logging.info(
            f"Maximum memory allocated so far is {torch.cuda.max_memory_allocated()//1000000}MB"
        )


def main():
    parser = get_parser()
    AsrDataModule.add_arguments(parser)
    args = parser.parse_args()
    args.exp_dir = Path(args.exp_dir)

    world_size = args.world_size
    assert world_size >= 1
    if world_size > 1:
        mp.spawn(run, args=(world_size, args), nprocs=world_size, join=True)
    else:
        run(rank=0, world_size=1, args=args)


torch.set_num_threads(1)
torch.set_num_interop_threads(1)

if __name__ == "__main__":
    main()
