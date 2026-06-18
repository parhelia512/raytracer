# Ray Tool

The root `ray` wrapper is the default workflow for samples. It reads `projects.xml`, builds the selected sample, passes shared benchmark arguments, captures process timing and memory, and can compare output images.

Per-language `run.bat` and `run.sh` scripts are intentionally not part of the workflow anymore. Keep build/run commands in `projects.xml` so local runs, CI, and Docker can use the same source of truth.

To build the tool on Windows install dotnet and build the project:

https://dotnet.microsoft.com/download/dotnet/5.0

```cmd
  dotnet build tools\Tools.csproj
```

## Compare image

```cmd
  ray imagediff --source "c\c-raytracer.bmp" --target "php\php-ray-tracer.bmp"
  ray imagediff "c\c-raytracer.bmp" "php\php-ray-tracer.bmp"

  #or just specify folder
  ray imagediff c php
```

## Measure time

Time command uses definitions from `projects.xml` to build and run a project.

Commands can be platform-specific. The runner picks the current OS first
(`Windows`, `Linux`, or `OSX`), then falls back to `Any`, then finally to the
old flat `Build`/`Run` shape if a command has not been migrated yet.

```xml
<Command Name="Default">
  <Platform Name="Windows">
    <Build Process="g++" Arguments="RayTracer.cpp -O2 -o RayTracer.exe" />
    <Run Process="RayTracer.exe" />
  </Platform>
  <Platform Name="Linux">
    <Build Process="g++" Arguments="RayTracer.cpp -O2 -o RayTracer" />
    <Run Process="./RayTracer" />
  </Platform>
</Command>
```

```cmd
  ray time --name php
  ray time --name c
  ray time --name c++

  # or
  ray time php
  ray time c
  ray time c++
```

The benchmark runner also accepts shared render settings and emits a stable summary:

```cmd
  ray time csharp --width 800 --height 600 --iterations 3
  ray time python --width 320 --height 240 --iterations 2 --format json
  ray time javascript --output render.bmp
  ray time-all --width 320 --height 240 --iterations 2 --format text
  ray time-all --width 320 --height 240 --iterations 2 --format json --timeout 60
```

Supported runner options:

| Option | Default | Description |
| ------ | ------- | ----------- |
| `--width` | `500` | Bitmap width passed to the sample. |
| `--height` | `500` | Bitmap height passed to the sample. |
| `--iterations` | `2` | Number of process runs. The first run is reported separately from warm runs. |
| `--format` | `text` | Use `json` for machine-readable output. |
| `--output` | empty | Optional bitmap path. The runner appends `-1`, `-2`, etc. per iteration. |

`time-all` runs every project in `projects.xml`, continues after failures, and
returns a non-zero exit code if any project fails or times out. Its `--timeout`
option is per project and defaults to 60 seconds. Text output is a Markdown
table sorted best-to-worst by the sample-reported warm render time, then peak
memory, so it can be copied into the README. Process timing is still included
as a separate column to show startup/runtime overhead. The text table displays
language names; JSON keeps project folder names for automation.

Samples should accept `--width`, `--height`, and `--output`, then print one render line in this form:

```text
render time_ms=123 width=500 height=500 output="sample.bmp"
```

The `time` command wraps every sample with process-level timing and peak memory data, so older samples can still be benchmarked while ports are updated to the shared CLI contract.

