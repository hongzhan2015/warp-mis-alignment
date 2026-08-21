# Warp + MissAlignment on CHTC

An unofficial, community-maintained recipe for building one
Apptainer/Singularity image containing [Warp](https://github.com/warpem/warp)
and [MissAlignment](https://github.com/warpem/miss-alignment), then running it
through HTCondor on [CHTC](https://chtc.cs.wisc.edu/). The image contains
CUDA 12.9 user-space libraries; the NVIDIA driver remains on the execution
host and is injected by CHTC's container runtime.

This project is not affiliated with the Warp, MissAlignment, or CHTC teams.

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

## Important notes

- The image does not include IMOD/Etomo. Warp recommends IMOD `>=4.12.50`, and
  the MissAlignment workflow may use Etomo patch tracking for initial
  alignment. Install/use IMOD separately if your workflow needs that step.
- CUDA 12.9 must be supported by the execution host's driver. The smoke test
  verifies the actual scheduled GPU/driver combination.
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
