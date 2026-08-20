# Third-party software

This repository contains an independent container recipe and HTCondor helper
scripts. It does not contain or redistribute the source code of the software
installed by the recipe.

The generated container downloads and installs third-party components with
their own licenses and terms, including:

- [Warp](https://github.com/warpem/warp) — GPL-3.0
- [MissAlignment](https://github.com/warpem/miss-alignment) — BSD-3-Clause
- [torch-projectors](https://github.com/warpem/torch-projectors) — MIT
- [PyTorch](https://github.com/pytorch/pytorch) — BSD-style license
- [CUDA Toolkit](https://developer.nvidia.com/cuda-toolkit) — NVIDIA license
- [micromamba](https://github.com/mamba-org/micromamba-releases) — BSD-3-Clause

Review the applicable upstream licenses before distributing a built `.sif`
image. The MIT license in this repository applies only to this repository's
original recipe, submit files, scripts, and documentation.

