using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
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

            BuildAndRun(selectedProject, command, width, height, iterations, format, output);
        }

        private void BuildAndRun(
            Project project,
            Command command,
            int width,
            int height,
            int iterations,
            string format,
            string output)
        {
            Directory.SetCurrentDirectory(Path.Join(baseDirectory, project.Path));

            Build(command.Build);
            Run(project, command.Run, width, height, Math.Max(iterations, 1), format, output);
        }

        private void Build(Build command)
        {
            if (command != null && !string.IsNullOrWhiteSpace(command.Process))
            {
                var startInfo = new ProcessStartInfo(command.Process, command.Arguments)
                {
                    UseShellExecute = false
                };
                ApplyBenchmarkEnvironment(startInfo, command.Process, command.Arguments);

                var process = Process.Start(startInfo);
                process.WaitForExit();
            }
        }

        private void Run(Project project, Run command, int width, int height, int iterations, string format, string output)
        {
            var runs = new List<RunResult>();

            for (var i = 0; i < iterations; i++)
            {
                runs.Add(RunOnce(command, width, height, output, i));
            }

            var result = BenchmarkResult.Create(project, width, height, runs);

            if (string.Compare(format, "json", true) == 0)
            {
                Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
                return;
            }

            Console.WriteLine($"benchmark name={result.Name} language=\"{result.Language}\" size={result.Width}x{result.Height} iterations={result.Iterations}");
            Console.WriteLine($"time first_ms={result.FirstRenderMs} warm_avg_ms={result.WarmAverageMs} min_ms={result.MinMs} max_ms={result.MaxMs}");
            Console.WriteLine($"memory peak_mb={result.PeakMemoryMb}");
            Console.WriteLine($"exit_codes {string.Join(",", result.ExitCodes)}");
        }

        private RunResult RunOnce(Run command, int width, int height, string output, int index)
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

            var watch = Stopwatch.StartNew();
            var process = Process.Start(startInfo);
            long peakWorkingSet = 0;

            while (!process.WaitForExit(100))
            {
                process.Refresh();
                peakWorkingSet = Math.Max(peakWorkingSet, TryGetPeakWorkingSet(process));
            }

            watch.Stop();
            peakWorkingSet = Math.Max(peakWorkingSet, TryGetPeakWorkingSet(process));

            return new RunResult
            {
                ElapsedMs = watch.ElapsedMilliseconds,
                PeakMemoryBytes = peakWorkingSet,
                ExitCode = process.ExitCode,
                Stdout = process.StandardOutput.ReadToEnd().Trim(),
                Stderr = process.StandardError.ReadToEnd().Trim()
            };
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

            startInfo.Environment["CARGO_HOME"] = cargoHome;
            startInfo.Environment["RUSTUP_HOME"] = rustupHome;

            var pathPrefix = Path.Combine(cargoHome, "bin");
            if (UsesCargo(process, arguments))
            {
                pathPrefix += ";" + mingwBin;
            }

            if (Directory.Exists(ghcBin))
            {
                pathPrefix += ";" + ghcBin;
            }

            startInfo.Environment["Path"] = pathPrefix + ";" + startInfo.Environment["Path"];
        }

        private static bool UsesCargo(string process, string arguments)
        {
            return (process ?? "").Contains("cargo", StringComparison.OrdinalIgnoreCase) ||
                (arguments ?? "").Contains("cargo", StringComparison.OrdinalIgnoreCase);
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
            public long MinMs { get; set; }
            public long MaxMs { get; set; }
            public double PeakMemoryMb { get; set; }
            public long[] RunTimesMs { get; set; }
            public int[] ExitCodes { get; set; }
            public string[] Stdout { get; set; }
            public string[] Stderr { get; set; }

            public static BenchmarkResult Create(Project project, int width, int height, List<RunResult> runs)
            {
                var times = runs.Select(r => r.ElapsedMs).ToArray();
                var warmTimes = times.Skip(1).DefaultIfEmpty(times[0]).ToArray();

                return new BenchmarkResult
                {
                    Name = project.Path,
                    Language = project.Language,
                    Width = width,
                    Height = height,
                    Iterations = runs.Count,
                    FirstRenderMs = times[0],
                    WarmAverageMs = Math.Round(warmTimes.Average(), 2),
                    MinMs = times.Min(),
                    MaxMs = times.Max(),
                    PeakMemoryMb = Math.Round(runs.Max(r => r.PeakMemoryBytes) / 1000.0 / 1000.0, 2),
                    RunTimesMs = times,
                    ExitCodes = runs.Select(r => r.ExitCode).ToArray(),
                    Stdout = runs.Select(r => r.Stdout).Where(s => !string.IsNullOrWhiteSpace(s)).ToArray(),
                    Stderr = runs.Select(r => r.Stderr).Where(s => !string.IsNullOrWhiteSpace(s)).ToArray()
                };
            }
        }
    }
}
