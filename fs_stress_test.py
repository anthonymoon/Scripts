#!/usr/bin/env python3
"""
Simplified Filesystem Stress Tester (Linux only)

This script runs high-stress filesystem performance tests on Linux systems. I
measures IOPS, latency, and bandwidth under various workload patterns and
stores results in a SQLite database for comparison between runs.

Features:
- Multiple test patterns (metadata-intensive, random writes, mixed read/write)
- Automatic test sizing based on available disk space
- Storage device detection and analysis
- Results comparison with previous runs
- Root-optimized process priority

Requires root privileges and the 'fio' package.
Example usage: sudo python3 fs_stress_test.py /path/to/test/dir
"""

import os
import sys
import re
import time
import shutil
import sqlite3
import argparse
import subprocess
from typing import Tuple, Optional

import numpy as np


# ANSI color functions for consistent outpu
def red(text):
    """Format text in red ANSI color."""
    return f"\033[0;31m{text}\033[0m"

def green(text):
    """Format text in green ANSI color."""
    return f"\033[0;32m{text}\033[0m"

def yellow(text):
    """Format text in yellow ANSI color."""
    return f"\033[0;33m{text}\033[0m"

def blue(text):
    """Format text in blue (cyan) ANSI color."""
    return f"\033[0;36m{text}\033[0m"

def purple(text):
    """Format text in purple (magenta) ANSI color."""
    return f"\033[0;35m{text}\033[0m"


class FSStressTester:
    """Simplified filesystem stress tester for Linux systems."""

    def __init__(
        self, test_dir: str, test_size: str = None, db_file: str = None,
        jobs: int = 4, runtime: int = 20, repeat: int = 2
    ):
        """Initialize the filesystem stress tester with test parameters.

        Args:
            test_dir: Directory where test files will be created
            test_size: Size of test files (e.g., "4G", "512M"), auto-detected if None
            db_file: Path to SQLite database file, defaults to /tmp/fs_benchmark.db if None
            jobs: Number of concurrent test jobs to run
            runtime: Duration in seconds for each test run
            repeat: Number of times to repeat each test for averaging
        """
        self.test_dir = os.path.abspath(test_dir)
        self.num_jobs = jobs           # Concurrent jobs
        self.runtime_each = runtime    # Runtime (seconds per test run)
        self.runs = repeat             # Times to repeat each tes
        self.test_size = test_size
        self.db_file = db_file
        self.run_id = None
        self.physical_devices = []

        # Optimize process priority - requires roo
        self._optimize_process_priority()

        # Set test size if not provided
        if not self.test_size:
            self._auto_size_test_file()

        # Set database location if not provided
        if not self.db_file:
            self.db_file = "/tmp/fs_benchmark.db"

        # Create test directory if it doesn't exis
        os.makedirs(self.test_dir, exist_ok=True)

        # SSD-optimized parameters for fio
        self.ssd_params = "--direct=1 --ioengine=libaio --thread --verify=0 --norandommap"

        print(blue("=== System Information ==="))
        print(f"{yellow('Kernel:')} {os.uname().release}")
        print(f"{yellow('CPU:')} {self._get_cpu_info()}")
        print(f"{yellow('Memory:')} {self._get_memory_info()}")
        print(f"{yellow('Filesystem:')} {self._get_filesystem_type()}")
        print(f"{yellow('Mount options:')} {self._get_mount_options()}")
        print()

    def _optimize_process_priority(self) -> None:
        """Optimize process priority for better benchmark accuracy."""
        try:
            # Set real-time I/O class
            subprocess.run(
                ['ionice', '-c', '1', '-n', '0', '-p', str(os.getpid())],
                stderr=subprocess.DEVNULL,
                check=False
            )

            # Set highest CPU priority
            os.nice(-20)

            # Increase file descriptor limi
            import resource
            resource.setrlimit(resource.RLIMIT_NOFILE, (1048576, 1048576))

            print("Running with elevated process priority")
        except Exception as e:
            print(f"Warning: Unable to optimize process priority: {e}")

    def _auto_size_test_file(self) -> None:
        """Automatically size the test file based on available space."""
        try:
            # Check directory for space calculation
            check_dir = self.test_dir
            if not os.path.exists(check_dir):
                check_dir = os.path.dirname(check_dir)

            # Get available space in KB
            stats = os.statvfs(check_dir)
            free_space_kb = (stats.f_bavail * stats.f_frsize) // 1024

            # Use 10% of free space but no more than 4GB and no less than 256MB
            test_size_kb = free_space_kb // 10
            min_size_kb = 256 * 1024  # 256MB
            max_size_kb = 4 * 1024 * 1024  # 4GB

            if test_size_kb < min_size_kb:
                test_size_kb = min_size_kb
            elif test_size_kb > max_size_kb:
                test_size_kb = max_size_kb

            # Convert to GB or MB for better readability
            if test_size_kb >= 1024 * 1024:
                self.test_size = f"{test_size_kb // 1024 // 1024}G"
            else:
                self.test_size = f"{test_size_kb // 1024}M"

            print(f"Auto-sized test file to {self.test_size} based on available space")
        except Exception as e:
            # If auto-sizing fails, use a safe defaul
            self.test_size = "1G"
            print(f"Warning: Error auto-sizing test file: {e}. Using default size: {self.test_size}")

    def _get_cpu_info(self) -> str:
        """Get CPU information."""
        try:
            with open('/proc/cpuinfo', 'r', encoding='utf-8') as f:
                for line in f:
                    if 'model name' in line:
                        return line.split(':', 1)[1].strip()
            return "Unknown CPU"
        except Exception as e:
            print(f"Warning: Could not get CPU info: {e}")
            return "Unknown CPU"

    def _get_memory_info(self) -> str:
        """Get system memory information."""
        try:
            result = subprocess.run(
                ['free', '-h'],
                capture_output=True,
                text=True,
                check=False
            )
            for line in result.stdout.split('\n'):
                if line.startswith('Mem:'):
                    return line.split()[1]
            return "Unknown"
        except Exception as e:
            print(f"Warning: Could not get memory info: {e}")
            return "Unknown"

    def _get_filesystem_type(self) -> str:
        """Get filesystem type for the test directory."""
        try:
            result = subprocess.run(
                ['df', '-Th', self.test_dir],
                capture_output=True,
                text=True,
                check=False
            )
            output_lines = result.stdout.strip().split('\n')
            return output_lines[1].split()[1]
        except Exception as e:
            print(f"Warning: Could not get filesystem type: {e}")
            return "Unknown"

    def _get_mount_options(self) -> str:
        """Get mount options for the test directory."""
        try:
            result = subprocess.run(
                ['df', '-P', self.test_dir],
                capture_output=True,
                text=True,
                check=False
            )
            output_lines = result.stdout.strip().split('\n')
            mount_point = output_lines[1].split()[5]

            with open('/proc/mounts', 'r', encoding='utf-8') as f:
                for line in f:
                    if mount_point in line:
                        return line.split()[3]
            return "Unknown"
        except Exception as e:
            print(f"Warning: Could not get mount options: {e}")
            return "Unknown"

    def init_database(self) -> None:
        """Initialize the SQLite database."""
        print(blue("Initializing benchmark database..."))

        try:
            conn = sqlite3.connect(self.db_file)
            cursor = conn.cursor()

            # Create simple tables if they don't exis
            cursor.execute('''
            CREATE TABLE IF NOT EXISTS test_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                kernel_version TEXT,
                test_dir TEXT NOT NULL,
                test_size TEXT NOT NULL
            )
            ''')

            cursor.execute('''
            CREATE TABLE IF NOT EXISTS test_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id INTEGER NOT NULL,
                test_name TEXT NOT NULL,
                iops REAL NOT NULL,
                latency_ms REAL NOT NULL,
                bandwidth_kbs REAL NOT NULL,
                FOREIGN KEY (run_id) REFERENCES test_runs(id)
            )
            ''')

            conn.commit()
            conn.close()

            print(f"Database initialized at: {self.db_file}")
        except sqlite3.Error as e:
            print(red(f"Error initializing database: {e}"))
            sys.exit(1)

    def save_run_metadata(self) -> None:
        """Save run metadata to database and get the run_id."""
        print(blue("Saving run metadata to database..."))

        try:
            kernel = os.uname().release

            conn = sqlite3.connect(self.db_file)
            cursor = conn.cursor()

            cursor.execute('''
            INSERT INTO test_runs
                (timestamp, kernel_version, test_dir, test_size)
            VALUES
                (datetime('now'), ?, ?, ?)
            ''', (kernel, self.test_dir, self.test_size))

            self.run_id = cursor.lastrowid
            conn.commit()
            conn.close()

            print(f"Run metadata saved with ID: {self.run_id}")
        except sqlite3.Error as e:
            print(red(f"Error saving run metadata: {e}"))
            sys.exit(1)

    def save_test_results(self, test_name: str, iops: float, latency: float, bandwidth: float) -> None:
        """Save test results to database."""
        try:
            # Use 0.0 for None or empty values
            iops = float(iops) if iops is not None else 0.0
            latency = float(latency) if latency is not None else 0.0
            bandwidth = float(bandwidth) if bandwidth is not None else 0.0

            conn = sqlite3.connect(self.db_file)
            cursor = conn.cursor()

            cursor.execute('''
            INSERT INTO test_results
                (run_id, test_name, iops, latency_ms, bandwidth_kbs)
            VALUES
                (?, ?, ?, ?, ?)
            ''', (self.run_id, test_name, iops, latency, bandwidth))

            conn.commit()
            conn.close()
        except sqlite3.Error as e:
            print(red(f"Warning: Could not save test results: {e}"))

    def get_previous_results(self, test_name: str) -> Tuple[Optional[float], Optional[float],
                                                             Optional[float]]:
        """Get the previous run's results for comparison."""
        try:
            conn = sqlite3.connect(self.db_file)
            cursor = conn.cursor()

            cursor.execute('''
            SELECT r.iops, r.latency_ms, r.bandwidth_kbs
            FROM test_results r
            JOIN test_runs tr ON r.run_id = tr.id
            WHERE r.test_name = ? AND tr.id < ?
            ORDER BY tr.id DESC
            LIMIT 1
            ''', (test_name, self.run_id))

            row = cursor.fetchone()
            conn.close()

            if row:
                return row[0], row[1], row[2]
            return None, None, None
        except sqlite3.Error as e:
            print(red(f"Warning: Could not get previous results: {e}"))
            return None, None, None

    def calc_percentage_change(self, current: float, previous: float, is_latency: bool = False) -> str:
        """Calculate percentage change between current and previous values."""
        if previous is None or previous == 0:
            return "N/A"

        try:
            change = ((current - previous) / previous) * 100

            if is_latency:
                # For latency, negative change is good
                if change < 0:
                    return green(f"{change:.2f}%")
                return red(f"+{change:.2f}%")

            # For IOPS and bandwidth, positive change is good
            if change < 0:
                return red(f"{change:.2f}%")
            return green(f"+{change:.2f}%")
        except Exception as e:
            print(f"Warning: Error calculating percentage change: {e}")
            return "N/A"

    def get_storage_info(self) -> None:
        """Get basic information about the storage device.

        Identifies the physical storage device hosting the test directory,
        determines if it's an SSD or HDD, and checks the active I/O scheduler.
        Prints this information to the console.
        """
        print(blue("=== Storage Device Analysis ==="))

        try:
            # Get the mount point for the directory
            result = subprocess.run(
                ['df', '-P', self.test_dir],
                capture_output=True,
                text=True,
                check=True
            )
            lines = result.stdout.strip().split('\n')
            if len(lines) < 2:
                raise ValueError("Could not determine mount point")

            fs_device = lines[1].split()[0]
            print(f"{yellow('Storage device:')} {fs_device}")
            self.physical_devices.append(fs_device)

            # Try to determine if it's an SSD
            device_name = os.path.basename(fs_device)
            if re.match(r'^[a-zA-Z]+[0-9]+$', device_name):
                device_name = re.sub(r'[0-9]+$', '', device_name)

            rotational_path = f"/sys/block/{device_name}/queue/rotational"
            if os.path.exists(rotational_path):
                with open(rotational_path, 'r', encoding='utf-8') as f:
                    if f.read().strip() == "0":
                        print(f"{yellow('Device type:')} SSD")
                    else:
                        print(f"{yellow('Device type:')} HDD (rotational)")

            # Check I/O scheduler
            scheduler_path = f"/sys/block/{device_name}/queue/scheduler"
            if os.path.exists(scheduler_path):
                with open(scheduler_path, 'r', encoding='utf-8') as f:
                    scheduler_data = f.read().strip()
                    match = re.search(r'\[(.*?)\]', scheduler_data)
                    if match:
                        print(f"{yellow('I/O scheduler:')} {match.group(1)}")
                    else:
                        print(f"{yellow('I/O scheduler:')} {scheduler_data}")

        except Exception as e:
            print(red(f"Error detecting storage device: {e}"))

    def extract_metric(self, output: str, metric: str) -> Optional[float]:
        """Extract the specified metric from fio output.

        Parses fio output text to extract performance metrics including IOPS,
        latency, and bandwidth. Handles different fio output formats and unit conversions.

        Args:
            output: Raw text output from the fio command
            metric: Which metric to extract - one of "iops", "lat", or "bw" (bandwidth)

        Returns:
            The extracted metric value as a float, or 0 if not found
        """
        try:
            # Extract IOPS from fio outpu
            if metric == "iops":
                # First try standard forma
                matches = re.search(r'iops\s*=\s*([0-9.]+)([kKMG]?)', output)
                if matches:
                    return self._convert_units(matches)

                # Try newer fio forma
                matches = re.search(r'IOPS\s*=\s*([0-9.]+)([kKMG]?)', output)
                if matches:
                    return self._convert_units(matches)

                return 0

            # Extract latency from fio outpu
            if metric == "lat":
                matches = re.search(r'lat.*?avg\s*=\s*([0-9.]+)', output)
                if matches:
                    return float(matches.group(1))
                return 0

            # Extract bandwidth from fio outpu
            if metric == "bw":
                # Try newer fio format first (KiB/s)
                matches = re.search(r'bw\s*=\s*([0-9.]+)([kKMG]?)iB/s', output)
                if matches:
                    return self._convert_units(matches, binary=True)

                # Fallback to older forma
                matches = re.search(r'bw\s*=\s*([0-9.]+)([kKMG]?)B/s', output)
                if matches:
                    return self._convert_units(matches, binary=True)

                return 0

            return None

        except Exception as e:
            print(red(f"Warning: Error extracting {metric}: {e}"))
            return 0

    def _convert_units(self, matches, binary=False) -> float:
        """Convert units from K/M/G to base numbers.

        Args:
            matches: Regex match object containing value and unit
            binary: If True, use 1024-based conversion instead of 1000-based

        Returns:
            Converted numeric value
        """
        val = float(matches.group(1))
        unit = matches.group(2).lower() if matches.group(2) else ''

        if not unit:
            return val
            
        # Define unit multipliers
        binary_multipliers = {'k': 1024, 'm': 1024**2, 'g': 1024**3}
        decimal_multipliers = {'k': 1000, 'm': 1000**2, 'g': 1000**3}
        
        # Get the appropriate multiplier based on unit and binary flag
        multipliers = binary_multipliers if binary else decimal_multipliers
        return val * multipliers.get(unit, 1)

    def drop_caches(self) -> None:
        """Drop system caches to ensure consistent benchmarking."""
        try:
            with open('/proc/sys/vm/drop_caches', 'w', encoding='utf-8') as f:
                f.write('3')
            subprocess.run(['sync'], check=False)
        except Exception as e:
            print(red(f"Error dropping caches: {e}"))

    def calculate_geomean(self, values: list) -> float:
        """Calculate geometric mean of a list of values, filtering out zeros and None."""
        valid_values = [x for x in values if x is not None and x > 0]
        return float(np.exp(np.mean(np.log(valid_values)))) if valid_values else 0.0

    def execute_fio_run(self, run_num: int, fio_options: str) -> Tuple[float, float, float]:
        """Execute a single fio benchmark run and return results."""
        try:
            # Build command with proper priority settings
            cmd = ['ionice', '-c', '1', '-n', '0', 'nice', '-n', '-20',
                 'fio'] + self.ssd_params.split() + fio_options.split()

            # Run fio and capture output
            process = subprocess.run(cmd, capture_output=True, text=True, check=True)
            output = process.stdout

            # Extract and validate metrics
            iops = self.extract_metric(output, "iops") or 0
            lat = self.extract_metric(output, "lat") or 0
            bw = self.extract_metric(output, "bw") or 0

            print(purple(
                f"Run {run_num} Results: IOPS={iops:.2f}, "
                f"Latency={lat:.2f} ms, Bandwidth={bw:.2f} KB/s"
            ))

            return iops, lat, bw

        except subprocess.SubprocessError as e:
            print(red(f"Error running fio: {e}"))
            return 0, 0, 0

    def display_results(self, test_name: str, metrics: Tuple[float, float, float],
                        prev_metrics: Tuple[Optional[float], Optional[float],
                                           Optional[float]]) -> None:
        """Display benchmark results with comparison to previous runs if available."""
        geomean_iops, geomean_lat, geomean_bw = metrics
        prev_iops, prev_latency, prev_bandwidth = prev_metrics

        print("")
        if prev_iops is not None:
            # Calculate percentage changes
            iops_change = self.calc_percentage_change(geomean_iops, prev_iops)
            lat_change = self.calc_percentage_change(geomean_lat, prev_latency, is_latency=True)
            bw_change = self.calc_percentage_change(geomean_bw, prev_bandwidth)

            # Print results with comparisons
            print(green(f"=== Results for {test_name} (with comparison) ==="))
            print(f"{yellow('IOPS:')} {geomean_iops:.2f} \t[Previous: {prev_iops:.2f} "
                  f"\tChange: {iops_change}]")
            print(f"{yellow('Latency:')} {geomean_lat:.2f} ms \t[Previous: {prev_latency:.2f} ms "
                  f"\tChange: {lat_change}]")
            print(f"{yellow('Bandwidth:')} {geomean_bw:.2f} KB/s \t"
                  f"[Previous: {prev_bandwidth:.2f} KB/s \tChange: {bw_change}]")
        else:
            # No previous results
            print(green(f"=== Results for {test_name} ==="))
            print(f"{yellow('IOPS:')} {geomean_iops:.2f}")
            print(f"{yellow('Latency:')} {geomean_lat:.2f} ms")
            print(f"{yellow('Bandwidth:')} {geomean_bw:.2f} KB/s")
            print(blue("(No previous test data available for comparison)"))

    def run_test(self, test_name: str, fio_options: str, description: str) -> None:
        """Run fio test multiple times and calculate geometric mean.

        Executes the specified fio benchmark test, repeats it multiple times,
        calculates geometric means of the results, and compares with previous runs.

        Args:
            test_name: Descriptive name for the test (used in reporting)
            fio_options: Command-line options to pass to fio
            description: Human-readable description of the tes
        """
        print(green(f"Running test: {test_name}"))
        print(f"{yellow('Description:')} {description}")

        # Arrays to store results
        results_iops, results_lat, results_bw = [], [], []

        # Drop caches before starting
        self.drop_caches()

        # Execute multiple test runs
        for run in range(1, self.runs + 1):
            print(blue(f"Run {run} of {self.runs}"))
            print(f"{yellow('Command:')} fio {self.ssd_params} {fio_options}")

            # Clear caches before each run
            self.drop_caches()

            # Run fio benchmark
            iops, lat, bw = self.execute_fio_run(run, fio_options)

            # Store results
            results_iops.append(iops)
            results_lat.append(lat)
            results_bw.append(bw)

            # Short pause between runs
            time.sleep(2)

        # Calculate geometric means
        geomean_iops = self.calculate_geomean(results_iops)
        geomean_lat = self.calculate_geomean(results_lat)
        geomean_bw = self.calculate_geomean(results_bw)

        # Save results to database
        self.save_test_results(test_name, geomean_iops, geomean_lat, geomean_bw)

        # Get previous results and display
        prev_metrics = self.get_previous_results(test_name)
        self.display_results(test_name, (geomean_iops, geomean_lat, geomean_bw), prev_metrics)

        print("")
        print(green(f"Completed test: {test_name}"))
        print("--------------------------------------------------------------")
        print("")

    def pre_allocate_file(self) -> str:
        """Pre-allocate test file and return its path.

        Returns:
            Path to the pre-allocated file
        """
        print(blue("Pre-allocating test file..."))
        preallocated_file = os.path.join(self.test_dir, "preallocated_file")

        try:
            # Try fallocate first (more efficient)
            if shutil.which('fallocate'):
                subprocess.run(['fallocate', '-l', self.test_size, preallocated_file], check=True)
                return preallocated_file

            # Convert size to MB for dd
            size_mb = 1024  # default 1GB
            if self.test_size.endswith('G'):
                size_mb = int(float(self.test_size[:-1]) * 1024)
            elif self.test_size.endswith('M'):
                size_mb = int(float(self.test_size[:-1]))

            # Use dd as fallback
            subprocess.run([
                'dd', 'if=/dev/zero', f'of={preallocated_file}',
                'bs=1M', f'count={size_mb}', 'status=progress'
            ], check=True)

        except Exception as e:
            print(red(f"Warning: Error pre-allocating file: {e}"))

        return preallocated_file

    def display_test_parameters(self) -> None:
        """Display test parameters at the beginning of test run."""
        print(blue("=== Test Parameters ==="))
        print(f"{yellow('Test directory:')} {self.test_dir}")
        print(f"{yellow('Test size:')} {self.test_size}")
        print(f"{yellow('Number of jobs:')} {self.num_jobs}")
        print(f"{yellow('Runtime per test:')} {self.runtime_each} seconds")
        print(f"{yellow('Number of runs per test:')} {self.runs}")
        print(f"{yellow('Database file:')} {self.db_file}")
        print("")

    def run_all_tests(self) -> None:
        """Run core filesystem stress tests.

        Executes a predefined set of filesystem benchmarks that test differen
        workload patterns and I/O characteristics:
        1. Metadata-intensive operations (many small files with fsync)
        2. Random write performance with synchronous I/O
        3. Mixed read/write workload typical of database environments

        Pre-allocates test files and cleans up afterward.
        """
        # Display test parameters
        self.display_test_parameters()

        # Create an empty file to pre-allocate space
        preallocated_file = self.pre_allocate_file()
        print("")

        # Define test workloads as a dictionary
        test_workloads = {
            "Metadata-Intensive": {
                "options": f"--directory={self.test_dir} --name=metadata_test --size=32M --nrfiles=1000 "
                          f"--rw=randwrite --bs=4k --sync=1 --fsync=1 --runtime={self.runtime_each} "
                          f"--time_based --numjobs={self.num_jobs} --group_reporting --iodepth=64 "
                          f"--file_service_type=random --ramp_time=5",
                "description": "Small files with synchronous writes, stressing filesystem metadata operations."
            },
            "Random Writes": {
                "options": f"--directory={self.test_dir} --name=rand_write --size={self.test_size} "
                          f"--rw=randwrite --bs=4k --sync=1 --runtime={self.runtime_each} "
                          f"--time_based --numjobs={self.num_jobs} --group_reporting --iodepth=64",
                "description": "Random write performance with synchronous I/O."
            },
            "Mixed ReadWrite": {
                "options": f"--directory={self.test_dir} --name=mixed_rw --size={self.test_size} "
                          f"--rw=randrw --rwmixread=70 --bs=8k --runtime={self.runtime_each} "
                          f"--time_based --numjobs={self.num_jobs} --group_reporting --iodepth=32",
                "description": "Mixed read/write workload with 70% reads, typical of database environments."
            }
        }
        
        # Run all defined tests using items() iteration
        for test_name, config in test_workloads.items():
            self.run_test(test_name, config["options"], config["description"])

        # Clean up
        print(blue("Cleaning up test files..."))
        try:
            os.remove(preallocated_file)
        except OSError:
            pass

        # Ensure all data is flushed to disk
        subprocess.run(['sync'], check=False)
        print("Done!")

    def run(self) -> None:
        """Run the full benchmark suite.

        This method orchestrates the entire benchmark process by:
        1. Setting up the SQLite database
        2. Saving test run metadata
        3. Analyzing storage device information
        4. Executing all defined benchmark tests
        5. Displaying a summary of results

        The benchmark results are stored in the SQLite database for later analysis
        and comparison with future benchmark runs.
        """
        # Initialize database
        self.init_database()

        # Save metadata to get run_id
        self.save_run_metadata()

        # Get basic storage device info
        self.get_storage_info()

        # Run all tests
        self.run_all_tests()

        # Final summary
        print("")
        print(green("All filesystem stress tests completed!"))
        print(f"Test results have been saved to the database at: {self.db_file}")
        print("")
        print(f"To view results: sqlite3 {self.db_file} 'SELECT * FROM test_results WHERE run_id = {self.run_id};'")


def parse_args():
    """Parse command-line arguments.

    Returns:
        argparse.Namespace: The parsed command-line arguments

    Command-line arguments:
        test_dir: Directory to store test files
        test_size: Size for test files (example: 4G, 512M)
        db_file: SQLite database file path
        -j/--jobs: Number of concurrent jobs
        -t/--time: Runtime in seconds for each test
        -r/--repeat: Number of times to repeat each test
    """
    parser = argparse.ArgumentParser(
        description="Run filesystem stress tests on Linux systems (requires root privileges)"
    )

    parser.add_argument(
        "test_dir", nargs="?", default="./fs_test",
        help="Directory to store test files (default: ./fs_test)"
    )

    parser.add_argument(
        "test_size", nargs="?", default=None,
        help="Size for test files (example: 4G, 512M, auto-detected if not specified)"
    )

    parser.add_argument(
        "db_file", nargs="?", default=None,
        help="SQLite database file path (default: /tmp/fs_benchmark.db)"
    )

    parser.add_argument(
        "-j", "--jobs", type=int, default=4,
        help="Number of concurrent jobs (default: 4)"
    )

    parser.add_argument(
        "-t", "--time", type=int, default=20,
        help="Runtime in seconds for each test (default: 20)"
    )

    parser.add_argument(
        "-r", "--repeat", type=int, default=2,
        help="Number of times to repeat each test (default: 2)"
    )

    return parser.parse_args()


def main() -> None:
    """Main entry point for the script.

    Checks for root privileges, parses command line arguments,
    initializes the FSStressTester with appropriate parameters,
    and runs the benchmark suite.

    Exits with status code 1 if not running as root.
    """
    # Check if running as roo
    if os.geteuid() != 0:
        print(red("This script must be run as root. Please use sudo."))
        sys.exit(1)

    # Parse arguments
    args = parse_args()

    # Create and run the stress tester
    tester = FSStressTester(
        test_dir=args.test_dir,
        test_size=args.test_size,
        db_file=args.db_file,
        jobs=args.jobs,
        runtime=args.time,
        repeat=args.repeat
    )
    tester.run()


if __name__ == "__main__":
    main()
