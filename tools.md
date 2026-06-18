# Tools

To build tools on Windows install dotnet and build project in "tools" directory:

https://dotnet.microsoft.com/download/dotnet/5.0

```cmd
    cd tools
    dotnet build
```

## Compare image

```cmd
  ray imagediff --source "c\c-raytracer.bmp" --target "php\php-ray-tracer.bmp"
  ray imagediff "c\c-raytracer.bmp" "php\php-ray-tracer.bmp"

  #or just specify folder
  ray imagediff c php
```

## Measure time

Time command uses definitions from projects.xml file to build and run project.

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
```

Supported runner options:

| Option | Default | Description |
| ------ | ------- | ----------- |
| `--width` | `500` | Bitmap width passed to the sample. |
| `--height` | `500` | Bitmap height passed to the sample. |
| `--iterations` | `2` | Number of process runs. The first run is reported separately from warm runs. |
| `--format` | `text` | Use `json` for machine-readable output. |
| `--output` | empty | Optional bitmap path. The runner appends `-1`, `-2`, etc. per iteration. |

Samples should accept `--width`, `--height`, and `--output`, then print one render line in this form:

```text
render time_ms=123 width=500 height=500 output="sample.bmp"
```

The `time` command wraps every sample with process-level timing and peak memory data, so older samples can still be benchmarked while ports are updated to the shared CLI contract.

