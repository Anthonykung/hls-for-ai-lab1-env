# ARC (Anthonian Runtime Configurator)

Linux-only setup script to give students a **reliable, reproducible Python environment** for the HLS for AI labs — with **CPU-only PyTorch** and sensible toolchain checks.
ARC prefers **conda** when available (and installs build tools there), otherwise, it uses a **Python venv** and verifies host tools. If conda fails at any point, ARC **automatically falls back to venv**.

> ✅ **Tested on OSU EECS servers:** Flip and Babylon
> 🧪 If you're having environment issues, **run this script** to create a clean lab environment.

---

## What's in this repo

* `setup.sh` – the setup script (run this)
* `requirements.txt` – extra Python deps for the course (won't override torch/vision/audio chosen by ARC)
* `.gitignore` – ignores typical virtual-env and cache artifacts

---

## Quick start

```bash
# from the repo root (Linux only)
bash setup.sh
```

ARC will:

1. Pick **conda** if available, else **venv** (you can force either).
2. Create/activate the environment.
3. Upgrade `pip`, install `pip-tools`.
4. Install **CPU-only** `torch`, `torchvision`, `torchaudio`.
5. Resolve & install `requirements.txt` **without** overriding torch packages.
6. Print versions and a short **cheat sheet**.

Logs: `install.log` (previous run in `install.log.1`)

---

## Usage

```bash
bash setup.sh [OPTIONS]

Options:
  --conda                 Prefer conda (falls back to venv if conda path fails)
  --venv                  Force Python venv (no conda attempt)
  --python X.Y            Python version (default is set in the script, e.g., 3.11)
  --name <env-name>       Conda env name (default: arc_env)
  --venv-dir <path>       Venv directory (default: .venv)
  -h, --help              Show detailed help
```

**Environment variable override** (when no flags are given):

```bash
ENV_MANAGER=conda bash setup.sh
ENV_MANAGER=venv  bash setup.sh
```

---

## Recommended commands after setup

### If ARC used **conda**

```bash
conda activate arc_env
python -c "import torch; print(torch.__version__); print(torch.cuda.is_available())"
conda deactivate
```

### If ARC used **venv**

```bash
source .venv/bin/activate
python -c "import torch; print(torch.__version__); print(torch.cuda.is_available())"
deactivate
```

> Note: ARC installs CPU-only PyTorch and confirms `torch.cuda.is_available()` is **False**.

---

## What ARC installs & safeguards

* **PyTorch (CPU wheels)**: `torch`, `torchvision`, `torchaudio` from the official CPU index when possible.
* **pip + pip-tools** (to resolve `requirements.txt` cleanly).
* **requirements.txt** packages are installed **with constraints** so they **cannot downgrade/replace** the torch stack ARC installed.

---

## Toolchain checks & minimums

ARC checks your build tools and reports versions.
If using **venv**: ARC **verifies** (but does not install) that your host meets the minimum requirements.
If using **conda**: ARC **installs** these from `conda-forge` (with version floors):

* `make` ≥ 4.3
* `gcc`  ≥ 11.5
* `g++`  ≥ 11.5
* `cmake` ≥ 3.26
* `pkg-config` (GNU) ≥ 0.29.2 **or** `pkgconf` ≥ 1.7.0

---

## Examples

Prefer conda with Python 3.11:

```bash
bash setup.sh --conda --python 3.11
```

Force venv to `.env/`:

```bash
bash setup.sh --venv --venv-dir .env
```

Re-run with an env var (auto-detect off):

```bash
ENV_MANAGER=venv bash setup.sh
```

---

## Verifying your environment

ARC prints a verification block like:

```
Python: 3.11.x
Torch: 2.x.y
CUDA available (should be False): False
Numpy: 1.x.y
✅ CPU-only PyTorch confirmed.
```

It also prints a **post-setup toolchain** summary (make/gcc/g++/cmake/pkg-config).

---

## Typical workflow for labs

1. **Run ARC** to set up your environment on Flip or Babylon.
2. **Activate** the created env (conda or venv).
3. **Work on labs** (run notebooks, compile C/C++ where needed).
4. If something breaks, **check `install.log`**, then re-run ARC or remove/recreate the env.

---

## Troubleshooting

**"This setup script supports Linux only."**
You're on macOS/Windows. Use the Linux lab servers (Flip/Babylon) or WSL on Windows (not supported by ARC).

**`python3-venv` missing (venv path):**
On some distros, you need to install the OS venv package (e.g., `sudo apt install python3-venv`). Re-run ARC.

**Conda command exists but is not initialized:**
Initialize conda so `conda.sh` is available (e.g., `conda init bash`; open a new shell) and re-run, or run ARC with `--venv`.

**Low disk space warning:**
ARC warns if free space < ~1.5 GB. Free up space and re-run.

**pkg-config / pkgconf version complaints:**
On the venv path, ARC only **verifies** versions. Upgrade system packages (or use the **conda** path so ARC installs modern tools there).

**`CXXABI` / libstdc++ version errors when importing Python packages:**
Prefer the **conda** path so modern C/C++ runtimes are **inside** the conda env. If you must use venv on an extremely old system, the system's libstdc++ may be too outdated.

**I already have some Torch installed and versions conflict:**
ARC pins torch/vision/audio after install and uses constraints so `requirements.txt` won't override them. If you manually changed them, re-run ARC.

**Where are the logs?**
`install.log` in the repo root (previous run is `install.log.1`).

---

## Cleaning up / starting over

**Conda:**

```bash
conda deactivate  # if active
conda remove -n arc_env --all -y
```

**Venv:**

```bash
deactivate  # if active
rm -rf .venv
```

Then re-run ARC.

---

## FAQ

**Q: Why CPU-only PyTorch?**
A: The course targets servers where GPU access may not be available, and CPU wheels are the most reliable baseline for all students.

**Q: Will ARC modify my system compilers?**
A: No. On the **venv** path, it only **checks** versions. On the **conda** path, it installs toolchains **inside the env** from `conda-forge`.

**Q: Can I add more packages later?**
A: Yes. Use `conda install <pkg>` in the conda env, or `pip install <pkg>` in the venv. Avoid changing the torch stack unless you know what you're doing.

---

## Support / Notes for Students

* If you hit any issues, **attach `install.log`** when asking for help.
* On Flip/Babylon, this script is the **recommended** way to get a working lab environment.
* If your environment is corrupted or inconsistent, **remove it and re-run ARC**.

Happy coding! 🎉
