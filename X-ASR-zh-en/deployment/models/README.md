# Model Files

The deployment model artifacts are tracked in this repository with Git LFS.

After cloning the repository, fetch the model files with:

```bash
git lfs pull
```

The same model artifacts are also available on Hugging Face:

```bash
hf download GilgameshWind/icefall_X_ASR_streaming \
  --local-dir ./X-ASR-zh-en/deployment
```

Expected model directories:

```text
models/
├── chunk-160ms-model/
├── chunk-480ms-model/
├── chunk-960ms-model/
└── chunk-1920ms-model/
```
