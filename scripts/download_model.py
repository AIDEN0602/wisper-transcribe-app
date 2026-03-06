import argparse
from pathlib import Path
from huggingface_hub import snapshot_download
ROOT = Path(__file__).resolve().parents[1]
MODELS_DIR = ROOT / "models"
MODELS_DIR.mkdir(parents=True, exist_ok=True)
def fetch(name):
    repo = f"Systran/faster-whisper-{name}"
    out = MODELS_DIR / f"faster-whisper-{name}"
    print(f"Downloading {repo} -> {out}")
    snapshot_download(repo_id=repo, token=False, local_dir=str(out), local_dir_use_symlinks=False)
if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("models", nargs="*", default=["small"])
    args = parser.parse_args()
    for m in args.models:
        fetch(m)
