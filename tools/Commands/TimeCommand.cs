using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using Tools.Application;
using Tools.Models;

namespace Tools.Commands
{
    public class TimeCommand
    {
        private string baseDirectory;

        [Command]
        public void Time(
            string name,
            int width = 500,
            int height = 500,
            int iterations = 2,
            string format = "text",
            string output = "")
        {
            baseDirectory = Directory.GetCurrentDirectory();
            var document = ProjectDocument.Load();
            var selectedProject = document.Projects.FirstOrDefault(p => string.Compare(p.Path, name, true) == 0);

            if (selectedProject == null)
            {
                Console.WriteLine($"Project '{name}' was not found in projects.xml");
                return;
            }

            var command = selectedProject.Commands.FirstOrDefault(x => string.Compare(x.Name, "default", true) == 0);
            if (command == null)
            {
                Console.WriteLine($"Project '{name}' does not have a default command");
                return;
            }

            var platform = SelectPlatform(command);
            if (platform == null)
            {
                Console.WriteLine($"Project '{name}' does not have a command for platform '{CurrentPlatformName()}' or 'Any'");
                return;
            }

            var result = BenchmarkProject(selectedProject, platform, width, height, Math.Max(iterations, 1), output, 0);
            PrintProjectResult(result, format, includeProjectHeader: false);
            Environment.ExitCode = result.Status == "ok" ? 0 : 1;
        }

        [Command]
        public void TimeAll(
            int width = 500,
            int height = 500,
            int iterations = 2,
            string format = "text",
            string output = "",
            int timeout = 60)
        {
            baseDirectory = Directory.GetCurrentDirectory();
            var document = ProjectDocument.Load();
            var results = new List<ProjectBenchmarkResult>();

            foreach (var project in document.Projects)
            {
                var command = project.Commands.FirstOrDefault(x => string.Compare(x.Name, "default", true) == 0);
                if (command == null)
                {
                    results.Add(ProjectBenchmarkResult.Failed(project, "Project does not have a default command"));
                    continue;
                }

                var platform = SelectPlatform(command);
                if (platform == null)
                {
                    results.Add(ProjectBenchmarkResult.Failed(project, $"Project does not have a command for platform '{CurrentPlatformName()}' or 'Any'"));
                    continue;
                }

                results.Add(BenchmarkProject(project, platform, width, height, Math.Max(iterations, 1), BuildProjectOutput(output, project), timeout * 1000));
            }

            var result = AllBenchmarkResult.Create(width, height, Math.Max(iterations, 1), timeout, results);
            if (string.Compare(format, "json", true) == 0)
            {
                Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
            }
            else
            {
                PrintAllResult(result);
            }

            Environment.ExitCode = result.Failed == 0 && result.TimedOut == 0 ? 0 : 1;
        }

        private ProjectBenchmarkResult BenchmarkProject(
            Project project,
            Platform platform,
            int width,
            int height,
            int iterations,
            string output,
            int timeoutMs)
        {
            var previousDirectory = Directory.GetCurrentDirectory();
            try
            {
                Directory.SetCurrentDirectory(Path.Join(baseDirectory, project.Path));

                var build = Build(platform.Build, timeoutMs);
                if (build.TimedOut)
                {
                    return ProjectBenchmarkResult.TimedOut(project, "Build timed out", build);
                }

                if (build.ExitCode != 0)
                {
                    return ProjectBenchmarkResult.Failed(project, "Build failed", build);
                }

                var run = Run(project, platform.Run, width, height, iterations, output, timeoutMs);
                run.Build = build;
                return run;
            }
            catch (Exception ex)
            {
                return ProjectBenchmarkResult.Failed(project, ex.Message);
            }
            finally
            {
                Directory.SetCurrentDirectory(previousDirectory);
            }
        }

        private static Platform SelectPlatform(Command command)
        {
            var currentPlatform = CurrentPlatformName();
            var platforms = command.Platforms ?? new List<Platform>();
            var platform = platforms.FirstOrDefault(x => string.Compare(x.Name, currentPlatform, true) == 0) ??
                platforms.FirstOrDefault(x => string.Compare(x.Name, "Any", true) == 0);

            if (platform != null)
            {
                return platform;
            }

            if (command.Build != null || command.Run != null)
            {
                return new Platform
                {
                    Name = "Legacy",
                    Build = command.Build,
                    Run = command.Run
                };
            }

            return null;
        }

        private static string CurrentPlatformName()
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                return "Windows";
            }

            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
            {
                return "Linux";
            }

            if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            {
                return "OSX";
            }

            return "Unknown";
        }

        private ProcessResult Build(Build command, int timeoutMs)
        {
            if (command != null && !string.IsNullOrWhiteSpace(command.Process))
            {
                var startInfo = new ProcessStartInfo(command.Process, command.Arguments)
                {
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                ApplyBenchmarkEnvironment(startInfo, command.Process, command.Arguments);

                return RunProcess(startInfo, timeoutMs);
            }

            return ProcessResult.Success();
        }

        private ProjectBenchmarkResult Run(Project project, Run command, int width, int height, int iterations, string output, int timeoutMs)
        {
            if (command == null || string.IsNullOrWhiteSpace(command.Process))
            {
                return ProjectBenchmarkResult.Failed(project, $"Project '{project.Path}' does not have a run command for platform '{CurrentPlatformName()}'");
            }

            var runs = new List<RunResult>();

            for (var i = 0; i < iterations; i++)
            {
                var run = RunOnce(command, width, height, output, i, timeoutMs);
                runs.Add(run);
                if (run.TimedOut)
                {
                    return ProjectBenchmarkResult.TimedOut(project, "Run timed out", runs);
                }
            }

            if (runs.Any(x => x.ExitCode != 0))
            {
                return ProjectBenchmarkResult.Failed(project, "Run failed", runs);
            }

            return ProjectBenchmarkResult.Ok(project, BenchmarkResult.Create(project, width, height, runs), runs);
        }

        private RunResult RunOnce(Run command, int width, int height, string output, int index, int timeoutMs)
        {
            var outputFile = string.IsNullOrWhiteSpace(output) ? "" : AddRunNumber(output, index);
            var arguments = JoinArguments(command.Arguments, BuildBenchmarkArguments(width, height, outputFile));
            var startInfo = new ProcessStartInfo(command.Process, arguments)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            ApplyBenchmarkEnvironment(startInfo, command.Process, command.Arguments);

            var result = RunProcess(startInfo, timeoutMs);
            return new RunResult
            {
                ElapsedMs = result.ElapsedMs,
                PeakMemoryBytes = result.PeakMemoryBytes,
                ExitCode = result.ExitCode,
                Stdout = result.Stdout,
                Stderr = result.Stderr,
                TimedOut = result.TimedOut
            };
        }

        private static ProcessResult RunProcess(ProcessStartInfo startInfo, int timeoutMs)
        {
            var watch = Stopwatch.StartNew();
            var process = Process.Start(startInfo);
            long peakWorkingSet = 0;

            while (!process.WaitForExit(100))
            {
                if (timeoutMs > 0 && watch.ElapsedMilliseconds >= timeoutMs)
                {
                    try
                    {
                        process.Kill(true);
                    }
                    catch
                    {
                        try
                        {
                            process.Kill();
                        }
                        catch
                        {
                        }
                    }

                    watch.Stop();
                    return new ProcessResult
                    {
                        ElapsedMs = watch.ElapsedMilliseconds,
                        PeakMemoryBytes = peakWorkingSet,
                        ExitCode = -1,
                        Stdout = process.StandardOutput.ReadToEnd().Trim(),
                        Stderr = process.StandardError.ReadToEnd().Trim(),
                        TimedOut = true
                    };
                }

                process.Refresh();
                peakWorkingSet = Math.Max(peakWorkingSet, TryGetPeakWorkingSet(process));
            }

            watch.Stop();
            peakWorkingSet = Math.Max(peakWorkingSet, TryGetPeakWorkingSet(process));

            return new ProcessResult
            {
                ElapsedMs = watch.ElapsedMilliseconds,
                PeakMemoryBytes = peakWorkingSet,
                ExitCode = process.ExitCode,
                Stdout = process.StandardOutput.ReadToEnd().Trim(),
                Stderr = process.StandardError.ReadToEnd().Trim(),
                TimedOut = false
            };
        }

        private static string BuildProjectOutput(string output, Project project)
        {
            if (string.IsNullOrWhiteSpace(output))
            {
                return "";
            }

            var directory = Path.GetDirectoryName(output);
            var extension = Path.GetExtension(output);
            var name = Path.GetFileNameWithoutExtension(output);
            var fileName = string.IsNullOrWhiteSpace(extension)
                ? $"{name}-{project.Path}.bmp"
                : $"{name}-{project.Path}{extension}";

            return string.IsNullOrWhiteSpace(directory)
                ? fileName
                : Path.Combine(directory, fileName);
        }

        private static void PrintProjectResult(ProjectBenchmarkResult result, string format, bool includeProjectHeader)
        {
            if (string.Compare(format, "json", true) == 0)
            {
                var jsonResult = result.Benchmark != null ? (object)result.Benchmark : result;
                Console.WriteLine(JsonSerializer.Serialize(jsonResult, new JsonSerializerOptions { WriteIndented = true }));
                return;
            }

            if (includeProjectHeader)
            {
                Console.WriteLine($"[{result.Status}] {result.Name} ({result.Language})");
            }

            if (!string.IsNullOrWhiteSpace(result.Build?.Stdout))
            {
                Console.WriteLine(result.Build.Stdout);
            }

            if (!string.IsNullOrWhiteSpace(result.Build?.Stderr))
            {
                Console.Error.WriteLine(result.Build.Stderr);
            }

            if (result.Benchmark != null)
            {
                var benchmark = result.Benchmark;
                Console.WriteLine($"benchmark name={benchmark.Name} language=\"{benchmark.Language}\" size={benchmark.Width}x{benchmark.Height} iterations={benchmark.Iterations}");
                Console.WriteLine($"time first_ms={benchmark.FirstRenderMs} warm_avg_ms={benchmark.WarmAverageMs} min_ms={benchmark.MinMs} max_ms={benchmark.MaxMs}");
                Console.WriteLine($"memory peak_mb={benchmark.PeakMemoryMb}");
                Console.WriteLine($"exit_codes {string.Join(",", benchmark.ExitCodes)}");
            }
            else
            {
                Console.WriteLine($"benchmark name={result.Name} language=\"{result.Language}\" status={result.Status} error=\"{result.Error}\"");
            }
        }

        private static void PrintAllResult(AllBenchmarkResult result)
        {
            Console.WriteLine($"Benchmark results: total={result.Total}, ok={result.Ok}, failed={result.Failed}, timed_out={result.TimedOut}, size={result.Width}x{result.Height}, iterations={result.Iterations}");
            Console.WriteLine();
            Console.WriteLine("| Rank | Language | Status | Render avg (ms) | Process avg (ms) | Peak memory (MB) | Error |");
            Console.WriteLine("| ---: | --- | --- | ---: | ---: | ---: | --- |");

            var rank = 1;
            foreach (var project in result.Projects)
            {
                if (project.Benchmark != null)
                {
                    Console.WriteLine($"| {rank} | {EscapeTableCell(project.Language)} | {project.Status} | {FormatOptionalNumber(project.Benchmark.RenderWarmAverageMs)} | {project.Benchmark.WarmAverageMs:0.##} | {project.Benchmark.PeakMemoryMb:0.##} |  |");
                    rank++;
                }
                else
                {
                    Console.WriteLine($"|  | {EscapeTableCell(project.Language)} | {project.Status} |  |  |  | {EscapeTableCell(project.Error)} |");
                }
            }
        }

        private static string EscapeTableCell(string value)
        {
            return (value ?? "").Replace("|", "\\|").Replace("\r", " ").Replace("\n", " ");
        }

        private static string FormatOptionalNumber(double? value)
        {
            return value.HasValue ? value.Value.ToString("0.##") : "";
        }

        private static List<ProjectBenchmarkResult> SortBenchmarkResults(List<ProjectBenchmarkResult> projects)
        {
            return projects
                .OrderBy(x => x.Benchmark == null ? 1 : 0)
                .ThenBy(x => x.Benchmark?.RenderWarmAverageMs ?? x.Benchmark?.WarmAverageMs ?? double.MaxValue)
                .ThenBy(x => x.Benchmark?.PeakMemoryMb ?? double.MaxValue)
                .ThenBy(x => x.Benchmark?.WarmAverageMs ?? double.MaxValue)
                .ThenBy(x => x.Language)
                .ToList();
        }

        private static string BuildBenchmarkArguments(int width, int height, string output)
        {
            var arguments = $"--width {width} --height {height}";
            if (!string.IsNullOrWhiteSpace(output))
            {
                arguments += $" --output \"{output}\"";
            }

            return arguments;
        }

        private static void ApplyBenchmarkEnvironment(ProcessStartInfo startInfo, string process, string arguments)
        {
            startInfo.Environment["GO111MODULE"] = "off";
            startInfo.Environment["TS_NODE_COMPILER_OPTIONS"] = "{\"module\":\"CommonJS\"}";
            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var cargoHome = Path.Combine(userProfile, "scoop", "persist", "rustup-gnu", ".cargo");
            var rustupHome = Path.Combine(userProfile, "scoop", "persist", "rustup-gnu", ".rustup");
            var mingwBin = Path.Combine(userProfile, "scoop", "apps", "mingw", "current", "bin");
            var ghcBin = @"C:\ProgramData\chocolatey\lib\ghc\tools\ghc-8.10.1\bin";
            var zigBin = Path.Combine(userProfile, "tools", "zig", "0.16.0");
            var vBin = Path.Combine(userProfile, "tools", "vlang", "v");
            var swiftBin = Path.Combine(userProfile, "AppData", "Local", "Programs", "Swift", "Toolchains", "6.3.2+Asserts", "usr", "bin");
            var swiftRuntimeBin = Path.Combine(userProfile, "AppData", "Local", "Programs", "Swift", "Runtimes", "6.3.2", "usr", "bin");
            var swiftSdk = Path.Combine(userProfile, "AppData", "Local", "Programs", "Swift", "Platforms", "6.3.2", "Windows.platform", "Developer", "SDKs", "Windows.sdk");

            var pathEntries = new List<string>();
            var cargoBin = Path.Combine(cargoHome, "bin");
            if (Directory.Exists(cargoHome))
            {
                startInfo.Environment["CARGO_HOME"] = cargoHome;
            }

            if (Directory.Exists(rustupHome))
            {
                startInfo.Environment["RUSTUP_HOME"] = rustupHome;
            }

            if (Directory.Exists(cargoBin))
            {
                pathEntries.Add(cargoBin);
            }

            if (UsesModernMingw(process, arguments) && Directory.Exists(mingwBin))
            {
                pathEntries.Add(mingwBin);
            }

            if (Directory.Exists(ghcBin))
            {
                pathEntries.Add(ghcBin);
            }

            if (Directory.Exists(zigBin))
            {
                pathEntries.Add(zigBin);
            }

            if (Directory.Exists(vBin))
            {
                pathEntries.Add(vBin);
            }

            if (Directory.Exists(swiftBin))
            {
                pathEntries.Add(swiftBin);
            }

            if (Directory.Exists(swiftRuntimeBin))
            {
                pathEntries.Add(swiftRuntimeBin);
            }

            if (Directory.Exists(swiftSdk))
            {
                startInfo.Environment["SDKROOT"] = swiftSdk;
            }

            if (pathEntries.Count > 0)
            {
                var pathVariable = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "Path" : "PATH";
                var currentPath = startInfo.Environment.ContainsKey(pathVariable)
                    ? startInfo.Environment[pathVariable]
                    : Environment.GetEnvironmentVariable(pathVariable) ?? "";

                startInfo.Environment[pathVariable] =
                    string.Join(Path.PathSeparator.ToString(), pathEntries.Concat(new[] { currentPath }));
            }
        }

        private static bool UsesModernMingw(string process, string arguments)
        {
            return (process ?? "").Contains("cargo", StringComparison.OrdinalIgnoreCase) ||
                (arguments ?? "").Contains("cargo", StringComparison.OrdinalIgnoreCase) ||
                (process ?? "").Equals("v", StringComparison.OrdinalIgnoreCase) ||
                (arguments ?? "").Contains(" v ", StringComparison.OrdinalIgnoreCase) ||
                (arguments ?? "").Contains("v -prod", StringComparison.OrdinalIgnoreCase);
        }

        private static long TryGetPeakWorkingSet(Process process)
        {
            try
            {
                process.Refresh();
                return process.PeakWorkingSet64;
            }
            catch (InvalidOperationException)
            {
                return 0;
            }
        }

        private static string JoinArguments(string existingArguments, string benchmarkArguments)
        {
            return string.IsNullOrWhiteSpace(existingArguments)
                ? benchmarkArguments
                : existingArguments + " " + benchmarkArguments;
        }

        private static string AddRunNumber(string output, int index)
        {
            var directory = Path.GetDirectoryName(output);
            var name = Path.GetFileNameWithoutExtension(output);
            var extension = Path.GetExtension(output);
            var numberedName = $"{name}-{index + 1}{extension}";

            return string.IsNullOrWhiteSpace(directory)
                ? numberedName
                : Path.Combine(directory, numberedName);
        }

        private class RunResult
        {
            public long ElapsedMs { get; set; }
            public long PeakMemoryBytes { get; set; }
            public int ExitCode { get; set; }
            public string Stdout { get; set; }
            public string Stderr { get; set; }
            public bool TimedOut { get; set; }
        }

        private class ProcessResult
        {
            public long ElapsedMs { get; set; }
            public long PeakMemoryBytes { get; set; }
            public int ExitCode { get; set; }
            public string Stdout { get; set; }
            public string Stderr { get; set; }
            public bool TimedOut { get; set; }

            public static ProcessResult Success()
            {
                return new ProcessResult
                {
                    ExitCode = 0,
                    Stdout = "",
                    Stderr = "",
                    TimedOut = false
                };
            }
        }

        private class ProjectBenchmarkResult
        {
            public string Name { get; set; }
            public string Language { get; set; }
            public string Status { get; set; }
            public string Error { get; set; }
            public ProcessResult Build { get; set; }
            public List<RunResult> Runs { get; set; }
            public BenchmarkResult Benchmark { get; set; }

            public static ProjectBenchmarkResult Ok(Project project, BenchmarkResult benchmark, List<RunResult> runs)
            {
                return new ProjectBenchmarkResult
                {
                    Name = project.Path,
                    Language = project.Language,
                    Status = "ok",
                    Error = "",
                    Runs = runs,
                    Benchmark = benchmark
                };
            }

            public static ProjectBenchmarkResult Failed(Project project, string error)
            {
                return Failed(project, error, null, null);
            }

            public static ProjectBenchmarkResult Failed(Project project, string error, ProcessResult build)
            {
                return Failed(project, error, build, null);
            }

            public static ProjectBenchmarkResult Failed(Project project, string error, List<RunResult> runs)
            {
                return Failed(project, error, null, runs);
            }

            public static ProjectBenchmarkResult TimedOut(Project project, string error, ProcessResult build)
            {
                var result = Failed(project, error, build, null);
                result.Status = "timeout";
                return result;
            }

            public static ProjectBenchmarkResult TimedOut(Project project, string error, List<RunResult> runs)
            {
                var result = Failed(project, error, null, runs);
                result.Status = "timeout";
                return result;
            }

            private static ProjectBenchmarkResult Failed(Project project, string error, ProcessResult build, List<RunResult> runs)
            {
                return new ProjectBenchmarkResult
                {
                    Name = project.Path,
                    Language = project.Language,
                    Status = "failed",
                    Error = error,
                    Build = build,
                    Runs = runs,
                    Benchmark = null
                };
            }
        }

        private class AllBenchmarkResult
        {
            public int Width { get; set; }
            public int Height { get; set; }
            public int Iterations { get; set; }
            public int TimeoutSeconds { get; set; }
            public int Total { get; set; }
            public int Ok { get; set; }
            public int Failed { get; set; }
            public int TimedOut { get; set; }
            public List<ProjectBenchmarkResult> Projects { get; set; }

            public static AllBenchmarkResult Create(int width, int height, int iterations, int timeoutSeconds, List<ProjectBenchmarkResult> projects)
            {
                return new AllBenchmarkResult
                {
                    Width = width,
                    Height = height,
                    Iterations = iterations,
                    TimeoutSeconds = timeoutSeconds,
                    Total = projects.Count,
                    Ok = projects.Count(x => x.Status == "ok"),
                    Failed = projects.Count(x => x.Status == "failed"),
                    TimedOut = projects.Count(x => x.Status == "timeout"),
                    Projects = SortBenchmarkResults(projects)
                };
            }
        }

        private class BenchmarkResult
        {
            public string Name { get; set; }
            public string Language { get; set; }
            public int Width { get; set; }
            public int Height { get; set; }
            public int Iterations { get; set; }
            public long FirstRenderMs { get; set; }
            public double WarmAverageMs { get; set; }
            public double? RenderFirstMs { get; set; }
            public double? RenderWarmAverageMs { get; set; }
            public long MinMs { get; set; }
            public long MaxMs { get; set; }
            public double PeakMemoryMb { get; set; }
            public long[] RunTimesMs { get; set; }
            public double[] RenderTimesMs { get; set; }
            public int[] ExitCodes { get; set; }
            public string[] Stdout { get; set; }
            public string[] Stderr { get; set; }

            public static BenchmarkResult Create(Project project, int width, int height, List<RunResult> runs)
            {
                var times = runs.Select(r => r.ElapsedMs).ToArray();
                var warmTimes = times.Skip(1).DefaultIfEmpty(times[0]).ToArray();
                var renderTimes = runs
                    .Select(r => TryParseRenderTime(r.Stdout))
                    .Where(t => t.HasValue)
                    .Select(t => t.Value)
                    .ToArray();
                var warmRenderTimes = renderTimes.Skip(1).DefaultIfEmpty(renderTimes.FirstOrDefault()).ToArray();

                return new BenchmarkResult
                {
                    Name = project.Path,
                    Language = project.Language,
                    Width = width,
                    Height = height,
                    Iterations = runs.Count,
                    FirstRenderMs = times[0],
                    WarmAverageMs = Math.Round(warmTimes.Average(), 2),
                    RenderFirstMs = renderTimes.Length > 0 ? Math.Round(renderTimes[0], 2) : null,
                    RenderWarmAverageMs = renderTimes.Length > 0 ? Math.Round(warmRenderTimes.Average(), 2) : null,
                    MinMs = times.Min(),
                    MaxMs = times.Max(),
                    PeakMemoryMb = Math.Round(runs.Max(r => r.PeakMemoryBytes) / 1000.0 / 1000.0, 2),
                    RunTimesMs = times,
                    RenderTimesMs = renderTimes,
                    ExitCodes = runs.Select(r => r.ExitCode).ToArray(),
                    Stdout = runs.Select(r => r.Stdout).Where(s => !string.IsNullOrWhiteSpace(s)).ToArray(),
                    Stderr = runs.Select(r => r.Stderr).Where(s => !string.IsNullOrWhiteSpace(s)).ToArray()
                };
            }

            private static double? TryParseRenderTime(string stdout)
            {
                if (string.IsNullOrWhiteSpace(stdout))
                {
                    return null;
                }

                var match = Regex.Match(stdout, @"render\s+time_ms=(?<time>(?:[0-9]+(?:\.[0-9]+)?)|(?:\.[0-9]+))");
                if (!match.Success)
                {
                    return null;
                }

                return double.TryParse(match.Groups["time"].Value, out var time) ? time : null;
            }
        }
    }
}
