# Cryo-ET GPU containers on CHTC

Unofficial, community-maintained recipes for building one
Apptainer/Singularity image containing [Warp](https://github.com/warpem/warp)
and [MissAlignment](https://github.com/warpem/miss-alignment), then running it
through HTCondor on [CHTC](https://chtc.cs.wisc.edu/). The image contains
CUDA 12.9 user-space libraries; the NVIDIA driver remains on the execution
host and is injected by CHTC's container runtime.

Separate images are provided for
[PyTom Match Pick](https://github.com/SBC-Utrecht/pytom-match-pick) and
[AreTomo3](https://github.com/czimaginginstitute/AreTomo3), keeping their CUDA
and library stacks isolated from Warp and MissAlignment.

This project is not affiliated with the upstream software projects or CHTC.

## Compatibility

The image deliberately uses two isolated environments because Warp's current
Conda artifact is built for Python 3.11 while MissAlignment's current install
instructions specify Python 3.12. Both environments are inside the same `.sif`
and their commands are on `PATH`.

The definition currently pins the compatibility-sensitive stack:

- Warp `2.0.0dev39`
- MissAlignment 0.2.0
- Python 3.11 for Warp; Python 3.12 for MissAlignment
- PyTorch 2.8.0 (CUDA 12.9 build)
- CUDA Toolkit 12.9
- torch-projectors 0.13.0

## 1. Copy these files to CHTC

From your computer, copy this directory to your CHTC home directory. On the
CHTC access point, enter the directory and create the log folder:

```bash
mkdir -p logs
chmod +x run_smoke_test.sh run_miss_alignment.sh run_warp.sh
```

## 2. Build the image on CHTC

CHTC requires image builds to run inside an interactive build job:

```bash
condor_submit -i apptainer-build.sub
apptainer build warp-miss-alignment.sif warp-miss-alignment.def
```

The build downloads several large CUDA packages. If it is killed for disk
usage, increase `request_disk` in `apptainer-build.sub` and retry.

Do not add `rm -rf /tmp/*` to the definition's `%post` cleanup. Apptainer uses
temporary rootfs and virtual-filesystem mounts under `/tmp` while building;
attempting to remove them causes a `Device or resource busy` failure near the
end of an otherwise successful build.

After a successful build, test the commands without a GPU:

```bash
apptainer exec warp-miss-alignment.sif WarpTools --help
apptainer exec warp-miss-alignment.sif miss-alignment --help
```

Move the large image to your CHTC staging area:

```bash
mv warp-miss-alignment.sif /staging/$USER/
```

If your CHTC staging path differs, use the path the facilitators assigned.

## 3. Run the GPU smoke test

Replace `USERNAME` in `smoke-test.sub`, then submit one small test:

```bash
condor_submit smoke-test.sub
condor_q
```

Inspect `logs/smoke_*.out` and `logs/smoke_*.err`. Do not start production
work until the output ends with `Warp, MissAlignment, and CUDA smoke test
passed.`

Some CHTC container jobs expose the assigned GPU and driver libraries without
binding the host's `nvidia-smi` executable into the container. The launchers
treat `nvidia-smi` as an optional diagnostic; the PyTorch CUDA assertion in the
smoke test is the authoritative check that the assigned GPU is usable.

## 4. Run MissAlignment

Keep the Warp project, input data, configuration, and outputs under staging so
they are visible to the job and persist across restarts. In the configuration,
use absolute `/staging/USERNAME/...` paths.

Edit `miss-alignment.sub`:

1. Replace `USERNAME` and `PROJECT`.
2. Confirm the image and config paths.
3. Adjust requested resources only after a small test.

Then submit:

```bash
condor_submit miss-alignment.sub
```

The supplied job follows the project's documented single-large-GPU layout:
one training device plus three reconstruction workers sharing logical device
0. It requests 40 GB VRAM, 8 CPU cores, and 64 GB RAM. HTCondor owns
`CUDA_VISIBLE_DEVICES`; the script deliberately does not change it.

To resume, change the final argument in the submit file from `0` to the last
completed iteration:

```text
arguments = /staging/USERNAME/PROJECT/config.yaml 3
```

For multi-GPU training, request all GPUs in the same Condor job and update the
device lists and CPU count together. MissAlignment does not support spreading
one training run over multiple nodes. A multi-GPU request may also wait much
longer in the queue, so establish that it is worthwhile with one dataset.

## 5. Run Warp

Edit `warp.sub`, replacing the placeholder image path and `arguments` with the
desired command. For example:

```text
arguments = WarpTools ts_ctf --settings /staging/USERNAME/PROJECT/warp_tiltseries.settings
```

Input/output paths should normally be under `/staging`. Resource needs vary
substantially by WarpTools command; the values in `warp.sub` are starting
points, not universal recommendations.

For the bundled TS_2 end-to-end test, `warp-pipeline.sub` runs settings
creation, frame-series CTF estimation, average export, TomoSTAR import,
tilt-series settings creation, IMOD alignment import, and reconstruction. Its
project path is currently configured as:

```text
/staging/hzhan3/warp-miss-alignment-test/2810_g1/output_TS_2_run001
```

Submit it after verifying the input directories described in
`run_warp_pipeline.sh`:

```bash
mkdir -p logs
condor_submit warp-pipeline.sub
```

For this TS_2 test, the launcher uses a `3.726 A` input/alignment pixel size,
tomogram dimensions of `4096x4096x2000`, and a `12 A` reconstruction pixel
size. The imported TomoSTAR is named `TS_2.st.tomostar`, so Warp identifies
the series as `TS_2.st`. The launcher keeps the original files in
`warp_alignment/TS_2/` and creates symbolic links with Warp's expected names:

```text
warp_alignment/TS_2.st/TS_2.st.xf
warp_alignment/TS_2.st/TS_2.st.tlt
```

If both dot-named (`TS_2.st.xf`, `TS_2.st.tlt`) and underscore-named
(`TS_2_st.xf`, `TS_2_st.tlt`) copies exist, the launcher prefers the dot-named
pair. Duplicate alternate names do not need to be removed.

If a previous alignment import failed, Warp marks the tilt series unselected.
The launcher runs `change_selection --select` before importing alignments so a
corrected retry processes the series.

The launcher deliberately starts WarpTools from an empty directory in local
Condor scratch while supplying absolute paths for the project. Warp dev39 can
time out while starting a worker if its current directory is a project tree on
networked storage, because the worker recursively initializes a filesystem
watcher before announcing its localhost port.

WarpTools metadata commands are an exception: the launcher runs
`create_settings`, `ts_import`, and `ts_import_alignments` from the project
directory with relative paths. Warp dev39 can reinterpret an absolute output
path as a relative path below the current directory, which would otherwise
place settings under a false `staging/...` tree in Condor scratch. GPU worker
commands still launch from the small local scratch directory.

The Warp launchers also add `localhost`, `127.0.0.1`, and `::1` to both
`NO_PROXY` and `no_proxy`. Warp's parent and GPU worker exchange heartbeats by
HTTP on a random loopback port, and an inherited site proxy can otherwise
intercept those requests and cause a worker connection timeout.

### Reconstruct a MissAlignment iteration

`run_warp_reconstruction.sub` reconstructs directly from the Warp XML snapshot
written by MissAlignment in `warp_tiltseries/iterN/`. Its three arguments are
the project directory, iteration number, and reconstruction pixel size. The
included TS_2 example reconstructs `iter8` at `12 A`:

```text
arguments = /staging/hzhan3/warp-miss-alignment-test/2810_g1/output_TS_2_run001 8 12
```

Change `8` to the iteration you want to evaluate, confirm that the matching
directory contains an XML file, and submit:

```bash
ls /staging/hzhan3/warp-miss-alignment-test/2810_g1/output_TS_2_run001/warp_tiltseries/iter8/*.xml
mkdir -p logs
condor_submit run_warp_reconstruction.sub
```

Results are written separately from the baseline reconstruction under:

```text
warp_tiltseries/iter8/reconstruction/
```

## 6. Build and run PyTom Match Pick

PyTom Match Pick is kept in a separate image to isolate its CuPy stack from
Warp and MissAlignment. The recipe pins PyTom Match Pick 0.14.0, Python 3.12,
CuPy 14.0.1, and CUDA 12.9.

Start a CHTC build job and build the image:

```bash
condor_submit -i pytom-build.sub
apptainer build pytom-match-pick.sif pytom-match-pick.def
mv pytom-match-pick.sif /staging/hzhan3/
exit
```

Test CuPy on an assigned GPU:

```bash
mkdir -p logs
condor_submit pytom-smoke-test.sub
```

The smoke-test output must end with `PyTom Match Pick and CUDA smoke test
passed.` before template matching is submitted.

The definition explicitly sets `CONDA_PREFIX` and `CUDA_PATH` because
Apptainer does not activate the conda environment when it runs `%test`. CuPy's
conda build uses those variables to locate CUDA in
`/opt/pytom-match-pick/targets/x86_64-linux`.

The build-time `%test` verifies installation and imports CuPy, but does not run
the PyTom command-line entry point. Its `voltools` dependency queries for a GPU
even when invoked with `--help`, and CHTC build nodes do not expose a compatible
runtime NVIDIA driver. The GPU smoke job performs that runtime validation.

`pytom-match.sub` is configured for the final TS_2 MissAlignment
reconstruction and its matching Warp XML. Before submitting, replace the
`TEMPLATE` and `MASK` paths and set `PARTICLE_DIAMETER` in Angstrom for the
target structure. The wrapper uses one assigned GPU and splits the tomogram
into `2x2x1` subvolumes to reduce GPU memory use:

```bash
condor_submit pytom-match.sub
```

Match maps, the job JSON, and other results persist under the staging-hosted
`DESTINATION` defined in the submit file.

## 7. Build and test AreTomo3

AreTomo3 is kept in a third image. Both recipes build AreTomo3 2.3.1 from the
exact upstream commit `8a068cf74cc25b8107a4dd1053689fe9f952b000` using CUDA
12.1.1. The final image contains the runtime libraries, AreTomo3 executable,
upstream license, and a small CUDA allocation probe.

To build the Docker image on a Linux machine with Docker:

```bash
docker build -f Dockerfile.aretomo3 -t aretomo3:2.3.1 .
docker run --rm --gpus all aretomo3:2.3.1 --version
```

For CHTC, build the equivalent Apptainer image in an interactive build job:

```bash
condor_submit -i aretomo3-build.sub
apptainer build aretomo3.sif aretomo3.def
mv aretomo3.sif /staging/hzhan3/
exit
```

The definition's `%test` checks the executable without requesting a GPU. Run
the separate GPU smoke test after creating the image:

```bash
mkdir -p logs
chmod +x run_aretomo3_smoke_test.sh
condor_submit aretomo3-smoke-test.sub
```

Its output must end with `AreTomo3 and CUDA smoke test passed.` The smoke job
requests compute capability 7.0 or newer because the upstream CUDA 12.1
makefile builds for `sm_70`, `sm_75`, `sm_80`, `sm_86`, `sm_89`, and `sm_90`.
This excludes CHTC P100 GPUs (`sm_60`) but includes the RTX 2080 Ti used by
your earlier tests.

The recipes compile the objects first and link the executable separately with
`-Xcompiler=-no-pie`. This is required because Ubuntu enables PIE linking by
default, while AreTomo3's bundled static libraries contain non-PIC objects.
Without this link option, the build fails with an `R_X86_64_32 ... recompile
with -fPIE` message.

The build uses upstream `makefile12`, which matches the CUDA 12.1 base image.
Do not substitute `makefile11`: in the pinned AreTomo3 2.3.1 source it omits
`MotionCor/MrcUtil/CLoadMrcMain.cpp`, producing undefined references to
`CLoadMrcMain` during the final link.

The Apptainer recipe stages the CUDA probe source under `/opt/src`. Do not
stage it under `/tmp`: Apptainer overlays that directory while running
`%post`, which can hide a file previously copied there by `%files`.

The Docker image uses `AreTomo3` as its entry point. Mount a data directory
and append the normal AreTomo3 options, for example:

```bash
docker run --rm --gpus all \
  -v /path/to/project:/data \
  aretomo3:2.3.1 \
  -InMrc /data/tilt-series.mrc -OutDir /data/aretomo3-output
```

That last command is only a path-layout example; add the microscope,
alignment, reconstruction, and GPU options required for your dataset. Keep
CHTC inputs and outputs under `/staging/hzhan3/...` so they persist after a
Condor job ends.

## Important notes

- The image does not include IMOD/Etomo. Warp recommends IMOD `>=4.12.50`, and
  the MissAlignment workflow may use Etomo patch tracking for initial
  alignment. Install/use IMOD separately if your workflow needs that step.
- CUDA 12.9 must be supported by the execution host's driver. The smoke test
  verifies the actual scheduled GPU/driver combination for Warp and PyTom.
  AreTomo3 uses CUDA 12.1.1 and has its own smoke test.
- `+GPUJobLength` is `short` (up to 12 hours), `medium` (default, up to 24
  hours), or `long` (up to 7 days) in CHTC's GPU Lab. The MissAlignment example
  requests `long`; checkpoint/resume from completed iterations.
- A staging-hosted image requires `requirements = (HasCHTCStaging == true)`.
  This intentionally excludes execution nodes that cannot see staging.
- The image is Linux x86-64 and must be built on CHTC/Linux, not on an Apple
  Silicon or Intel Mac host.

## License and attribution

The original recipe, submit files, scripts, and documentation in this
repository are available under the [MIT License](LICENSE). Software installed
inside the generated container remains subject to its respective upstream
license. See [NOTICE.md](NOTICE.md) before redistributing a built image.
