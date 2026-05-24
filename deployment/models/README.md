# Model Files

Large model artifacts are hosted on Hugging Face instead of GitHub.

Download the pretrained deployment models with:

```bash
hf download GilgameshWind/icefall_X_ASR_streaming \
  --local-dir ./deployment
```

Expected model directories:

```text
models/
├── chunk-160ms-model/
├── chunk-480ms-model/
├── chunk-960ms-model/
└── chunk-1920ms-model/
```

