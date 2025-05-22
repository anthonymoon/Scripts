#!/usr/bin/env python3
# Run with mypy --strict flag
"""
Simplified Filesystem Stress Tester (Linux only)

This script runs high-stress filesystem performance tests on Linux systems. It
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
import resource
import subprocess
from typing import Tuple, Optional, Dict, List, Any, Match as ReMatch, cast

import numpy as np


# ANSI color functions for consistent output
def red(text: str) -> str:
    """Format text in red ANSI color."""
    return f"\033[0;31m{text}\033[0m"


def green(text: str) -> str:
    """Format text in green ANSI color."""
    return f"\033[0;32m{text}\033[0m"


def yellow(text: str) -> str:
    """Format text in yellow ANSI color."""
    return f"\033[0;33m{text}\033[0m"


def blue(text: str) -> str:
    """Format text in blue (cyan) ANSI color."""
    return f"\033[0;36m{text}\033[0m"


def purple(text: str) -> str:
    """Format text in purple (magenta) ANSI color."""
    return f"\033[0;35m{text}\033[0m"


class TestConfig:
    """Configuration object for filesystem stress tests."""
    def __init__(self, test_dir: str, config_dict: Optional[Dict[str, Any]] = None) -> None:
        """Initialize test configuration.

        Args:
            test_dir: Directory where test files will be created
            config_dict: Optional dictionary with configuration parameters:
                - test_size: Size of test files (e.g., "4G", "512M"), auto-detected if None
                - db_file: Path to SQLite database file, defaults to /tmp/fs_benchmark.db if None
                - jobs: Number of concurrent test jobs to run (default: 4)
                - runtime: Duration in seconds for each test run (default: 20)
                - repeat: Number of times to repeat each test for averaging (default: 2)
        """
        config: Dict[str, Any] = config_dict or {}
        self.test_dir: str = os.path.abspath(test_dir)
        self.test_size: Optional[str] = config.get('test_size')
        self.db_file: str = config.get('db_file') or "/tmp/fs_benchmark.db"
        self.num_jobs: int = config.get('jobs', 4)
        self.runtime_each: int = config.get('runtime', 20)
        self.runs: int = config.get('repeat', 2)

    def validate(self) -> None:
        """Validate configuration parameters."""
        if self.num_jobs < 1:
            raise ValueError("Number of jobs must be at least 1")
        if self.runtime_each < 1:
            raise ValueError("Runtime must be at least 1 second")
        if self.runs < 1:
            raise ValueError("Number of repeat runs must be at least 1")

    def get_formatted_params(self) -> str:
        """Get a formatted string with configuration parameters.

        Returns:
            A formatted string representation of the configuration parameters
        """
        return (
            f"Test directory: {self.test_dir}\n"
            f"Test size: {self.test_size or 'Auto-detected'}\n"
            f"Jobs: {self.num_jobs}\n"
            f"Runtime: {self.runtime_each}s\n"
            f"Repeats: {self.runs}\n"
            f"Database: {self.db_file}"
        )


class FSStressTester:
    """Simplified filesystem stress tester for Linux systems."""

    def __init__(self, config: TestConfig):
        """Initialize the filesystem stress tester with test parameters.

        Args:
            config: Test configuration object containing all test parameters
        """
        self.config = config
        self.run_id: Optional[int] = None
        self.physical_devices: List[str] = []
        # Create test directory if it doesn't exist
        os.makedirs(self.config.test_dir, exist_ok=True)
        # Optimize process priority - requires root
        self._optimize_process_priority()
        # Set test size if not provided
        if not self.config.test_size:
            self._auto_size_test_file()

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
            # Increase file descriptor limit
            resource.setrlimit(resource.RLIMIT_NOFILE, (1048576, 1048576))
            print("Running with elevated process priority")
        except (OSError, ValueError, subprocess.SubprocessError) as err:
            print(f"Warning: Unable to optimize process priority: {err}")

    def _auto_size_test_file(self) -> None:
        """Automatically size the test file based on available space."""
        try:
            # Check directory for space calculation
            check_dir = self.config.test_dir
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
                self.config.test_size = f"{test_size_kb // 1024 // 1024}G"
            else:
                self.config.test_size = f"{test_size_kb // 1024}M"

            print(f"Auto-sized test file to {self.config.test_size} based on available space")
        except (OSError, ValueError) as err:
            # If auto-sizing fails, use a safe default
            self.config.test_size = "1G"
            size_msg = f"Using default size: {self.config.test_size}"
            print(f"Warning: Error auto-sizing test file: {err}. {size_msg}")

    def _get_cpu_info(self) -> str:
        """Get CPU information."""
        try:
            with open('/proc/cpuinfo', 'r', encoding='utf-8') as f:
                for line in f:
                    if 'model name' in line:
                        return line.split(':', 1)[1].strip()
            return "Unknown CPU"
        except (IOError, OSError) as err:
            print(f"Warning: Could not get CPU info: {err}")
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
        except (subprocess.SubprocessError, IndexError) as err:
            print(f"Warning: Could not get memory info: {err}")
            return "Unknown"

    def _get_filesystem_type(self) -> str:
        """Get filesystem type for the test directory."""
        try:
            result = subprocess.run(
                ['df', '-Th', self.config.test_dir],
                capture_output=True,
                text=True,
                check=False
            )
            output_lines = result.stdout.strip().split('\n')
            return output_lines[1].split()[1]
        except (subprocess.SubprocessError, IndexError) as err:
            print(f"Warning: Could not get filesystem type: {err}")
            return "Unknown"

    def _get_mount_options(self) -> str:
        """Get mount options for the test directory."""
        try:
            result = subprocess.run(
                ['df', '-P', self.config.test_dir],
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
        except (subprocess.SubprocessError, IndexError, IOError) as err:
            print(f"Warning: Could not get mount options: {err}")
            return "Unknown"

    def init_database(self) -> None:
        """Initialize the SQLite database."""
        print(blue("Initializing benchmark database..."))

        try:
            conn = sqlite3.connect(self.config.db_file)
            cursor = conn.cursor()

            # Create simple tables if they don't exist
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

            print(f"Database initialized at: {self.config.db_file}")
        except sqlite3.Error as err:
            print(red(f"Error initializing database: {err}"))
            sys.exit(1)

    def save_run_metadata(self) -> None:
        """Save run metadata to database and get the run_id."""
        print(blue("Saving run metadata to database..."))

        try:
            kernel = os.uname().release

            conn = sqlite3.connect(self.config.db_file)
            cursor = conn.cursor()

            cursor.execute('''
            INSERT INTO test_runs
                (timestamp, kernel_version, test_dir, test_size)
            VALUES
                (datetime('now'), ?, ?, ?)
            ''', (kernel, self.config.test_dir, self.config.test_size))

            self.run_id = cast(int, cursor.lastrowid)
            conn.commit()
            conn.close()

            print(f"Run metadata saved with ID: {self.run_id}")
        except sqlite3.Error as err:
            print(red(f"Error saving run metadata: {err}"))
            sys.exit(1)

    def save_test_results(self, test_name: str, iops: float, latency: float,
                         bandwidth: float) -> None:
        """Save test results to database."""
        try:
            # Use 0.0 for None or empty values
            iops_val = float(iops) if iops is not None else 0.0
            latency_val = float(latency) if latency is not None else 0.0
            bandwidth_val = float(bandwidth) if bandwidth is not None else 0.0

            conn = sqlite3.connect(self.config.db_file)
            cursor = conn.cursor()

            cursor.execute('''
            INSERT INTO test_results
                (run_id, test_name, iops, latency_ms, bandwidth_kbs)
            VALUES
                (?, ?, ?, ?, ?)
            ''', (self.run_id, test_name, iops_val, latency_val, bandwidth_val))

            conn.commit()
            conn.close()
        except sqlite3.Error as err:
            print(red(f"Warning: Could not save test results: {err}"))

    def get_previous_results(self, test_name: str) -> Tuple[
            Optional[float], Optional[float], Optional[float]]:
        """Get the previous run's results for comparison."""
        try:
            conn = sqlite3.connect(self.config.db_file)
            cursor = conn.cursor()

            cursor.execute('''
            SELECT r.iops, r.latency_ms, r.bandwidth_kbs
            FROM test_results r
            JOIN test_runs tr ON r.run_id = tr.id
            WHERE r.test_name = ?
              AND tr.id < ?
            ORDER BY tr.id DESC
            LIMIT 1
            ''', (test_name, self.run_id))

            row = cursor.fetchone()
            conn.close()

            if row:
                return row[0], row[1], row[2]
            return None, None, None
        except sqlite3.Error as err:
            print(red(f"Warning: Could not get previous results: {err}"))
            return None, None, None

    def calc_percentage_change(self, current: float, previous: Optional[float],
                               is_latency: bool = False) -> str:
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
        except (ValueError, ZeroDivisionError, TypeError) as err:
            print(f"Warning: Error calculating percentage change: {err}")
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
                ['df', '-P', self.config.test_dir],
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

        except (subprocess.SubprocessError, ValueError, IOError) as err:
            print(red(f"Error detecting storage device: {err}"))

    def _convert_units(self, matches: ReMatch[str], binary: bool = False) -> float:
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
            # Handle different metric types
            if metric == "iops":
                return self._extract_iops(output)
            if metric == "lat":
                return self._extract_latency(output)
            if metric == "bw":
                return self._extract_bandwidth(output)
            return None
        except (ValueError, TypeError, AttributeError) as err:
            print(red(f"Warning: Error extracting {metric}: {err}"))
            return 0

    def _extract_iops(self, output: str) -> float:
        """Extract IOPS value from fio output.

        Args:
            output: Raw text output from the fio command

        Returns:
            The extracted IOPS value as a float
        """
        # First try standard format
        matches = re.search(r'iops\s*=\s*([0-9.]+)([kKMG]?)', output)
        if matches:
            return self._convert_units(matches)

        # Try newer fio format
        matches = re.search(r'IOPS\s*=\s*([0-9.]+)([kKMG]?)', output)
        if matches:
            return self._convert_units(matches)

        return 0

    def _extract_latency(self, output: str) -> float:
        """Extract latency value from fio output.

        Args:
            output: Raw text output from the fio command

        Returns:
            The extracted latency value as a float
        """
        matches = re.search(r'lat.*?avg\s*=\s*([0-9.]+)', output)
        if matches:
            return float(matches.group(1))
        return 0

    def _extract_bandwidth(self, output: str) -> float:
        """Extract bandwidth value from fio output.

        Args:
            output: Raw text output from the fio command

        Returns:
            The extracted bandwidth value as a float in KB/s
        """
        # Try newer fio format first (KiB/s)
        matches = re.search(r'bw\s*=\s*([0-9.]+)([kKMG]?)iB/s', output)
        if matches:
            return self._convert_units(matches, binary=True)

        # Fallback to older format
        matches = re.search(r'bw\s*=\s*([0-9.]+)([kKMG]?)B/s', output)
        if matches:
            return self._convert_units(matches, binary=True)

        return 0

    def _format_bandwidth(self, bw_kbs: float) -> str:
        """Format bandwidth in appropriate units (KB/s, MB/s, or GB/s).

        Args:
            bw_kbs: Bandwidth in KB/s

        Returns:
            Formatted string with appropriate units
        """
        if bw_kbs >= 1048576:  # 1 GB/s = 1024*1024 KB/s
            return f"{bw_kbs/1048576:.2f} GB/s"
        if bw_kbs >= 1024:   # 1 MB/s = 1024 KB/s
            return f"{bw_kbs/1024:.2f} MB/s"
        return f"{bw_kbs:.2f} KB/s"

    def drop_caches(self) -> None:
        """Drop system caches to ensure consistent benchmarking."""
        try:
            with open('/proc/sys/vm/drop_caches', 'w', encoding='utf-8') as f:
                f.write('3')
            subprocess.run(['sync'], check=False)
        except (IOError, subprocess.SubprocessError) as err:
            print(red(f"Error dropping caches: {err}"))

    def calculate_geomean(self, values: List[float]) -> float:
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

            formatted_bw = self._format_bandwidth(bw)
            print(purple(
                f"Run {run_num} Results: IOPS={iops:.2f}, "
                f"Latency={lat:.2f} ms, Bandwidth={formatted_bw}"
            ))

            return iops, lat, bw

        except subprocess.SubprocessError as err:
            print(red(f"Error running fio: {err}"))
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
            # We know prev values are not None in this block
            iops_change = self.calc_percentage_change(geomean_iops, prev_iops)
            lat_change = self.calc_percentage_change(geomean_lat, prev_latency, is_latency=True)
            bw_change = self.calc_percentage_change(geomean_bw, prev_bandwidth)

            # Format bandwidth values
            formatted_bw = self._format_bandwidth(geomean_bw)
            # prev_bandwidth is not None at this point but mypy needs the explicit check
            if prev_bandwidth is not None:
                formatted_prev_bw = self._format_bandwidth(prev_bandwidth)
            else:
                formatted_prev_bw = "0.00 KB/s"
            # Print results with comparisons
            print(green(f"=== Results for {test_name} (with comparison) ==="))
            print(f"{yellow('IOPS:')} {geomean_iops:.2f} \t[Previous: {prev_iops:.2f} "
                  f"\tChange: {iops_change}]")
            print(f"{yellow('Latency:')} {geomean_lat:.2f} ms \t"
                  f"[Previous: {prev_latency:.2f} ms \tChange: {lat_change}]")
            print(f"{yellow('Bandwidth:')} {formatted_bw} \t"
                  f"[Previous: {formatted_prev_bw} \tChange: {bw_change}]")
        else:
            # No previous results
            formatted_bw = self._format_bandwidth(geomean_bw)
            print(green(f"=== Results for {test_name} ==="))
            print(f"{yellow('IOPS:')} {geomean_iops:.2f}")
            print(f"{yellow('Latency:')} {geomean_lat:.2f} ms")
            print(f"{yellow('Bandwidth:')} {formatted_bw}")
            print(blue("(No previous test data available for comparison)"))

    def run_test(self, test_name: str, fio_options: str, description: str) -> None:
        """Run fio test multiple times and calculate geometric mean.

        Executes the specified fio benchmark test, repeats it multiple times,
        calculates geometric means of the results, and compares with previous runs.

        Args:
            test_name: Descriptive name for the test (used in reporting)
            fio_options: Command-line options to pass to fio
            description: Human-readable description of the test
        """
        print(green(f"Running test: {test_name}"))
        print(f"{yellow('Description:')} {description}")

        # Arrays to store results
        results_iops, results_lat, results_bw = [], [], []

        # Drop caches before starting
        self.drop_caches()

        # Execute multiple test runs
        for run in range(1, self.config.runs + 1):
            print(blue(f"Run {run} of {self.config.runs}"))
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
        preallocated_file = os.path.join(self.config.test_dir, "preallocated_file")

        try:
            # Try fallocate first (more efficient)
            if shutil.which('fallocate') and self.config.test_size is not None:
                subprocess.run(
                    ['fallocate', '-l', self.config.test_size, preallocated_file],
                    check=True
                )
                return preallocated_file

            # Convert size to MB for dd
            size_mb = 1024  # default 1GB
            if self.config.test_size is not None:
                if self.config.test_size.endswith('G'):
                    size_mb = int(float(self.config.test_size[:-1]) * 1024)
                elif self.config.test_size.endswith('M'):
                    size_mb = int(float(self.config.test_size[:-1]))

            # Use dd as fallback
            subprocess.run([
                'dd', 'if=/dev/zero', f'of={preallocated_file}',
                'bs=1M', f'count={size_mb}', 'status=progress'
            ], check=True)

        except (subprocess.SubprocessError, ValueError) as err:
            print(red(f"Warning: Error pre-allocating file: {err}"))

        return preallocated_file

    def display_test_parameters(self) -> None:
        """Display test parameters at the beginning of test run."""
        print(blue("=== Test Parameters ==="))
        print(f"{yellow('Test directory:')} {self.config.test_dir}")
        print(f"{yellow('Test size:')} {self.config.test_size}")
        print(f"{yellow('Number of jobs:')} {self.config.num_jobs}")
        print(f"{yellow('Runtime per test:')} {self.config.runtime_each} seconds")
        print(f"{yellow('Number of runs per test:')} {self.config.runs}")
        print(f"{yellow('Database file:')} {self.config.db_file}")
        print("")

    def run_all_tests(self) -> None:
        """Run core filesystem stress tests.

        Executes a predefined set of filesystem benchmarks that test different
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
        # Define common parameters
        base_opts = f"--time_based --numjobs={self.config.num_jobs} --group_reporting"

        test_workloads = {
            "Metadata-Intensive": {
                "options": (f"--directory={self.config.test_dir} --name=metadata_test --size=32M "
                           f"--nrfiles=1000 --rw=randwrite --bs=4k --sync=1 --fsync=1 "
                           f"--runtime={self.config.runtime_each} {base_opts} "
                           f"--iodepth=64 --file_service_type=random --ramp_time=5"),
                "description": "Small files with synchronous writes, testing metadata operations."
            },
            "Random Writes": {
                "options": (f"--directory={self.config.test_dir} --name=rand_write "
                           f"--size={self.config.test_size} --rw=randwrite --bs=4k --sync=1 "
                           f"--runtime={self.config.runtime_each} {base_opts} --iodepth=64"),
                "description": "Random write performance with synchronous I/O."
            },
            "Mixed ReadWrite": {
                "options": (f"--directory={self.config.test_dir} --name=mixed_rw "
                           f"--size={self.config.test_size} --rw=randrw --rwmixread=70 "
                           f"--bs=8k --runtime={self.config.runtime_each} "
                           f"{base_opts} --iodepth=32"),
                "description": "Mixed read/write (70% reads), typical of database environments."
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
        print(f"Test results have been saved to the database at: {self.config.db_file}")
        print("")
        query = f"SELECT * FROM test_results WHERE run_id = {self.run_id}"
        print(f"To view results: sqlite3 {self.config.db_file} '{query};'")


def get_argument_parser() -> argparse.ArgumentParser:
    """Create and configure the argument parser.

    Returns:
        Configured argument parser
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
    return parser


def parse_args() -> argparse.Namespace:
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
    parser = get_argument_parser()
    return parser.parse_args()


def main() -> None:
    """Main entry point for the script.

    Checks for root privileges, parses command line arguments,
    initializes the FSStressTester with appropriate parameters,
    and runs the benchmark suite.

    Exits with status code 1 if not running as root.
    """
    # Check if running as root
    if os.geteuid() != 0:
        print(red("This script must be run as root. Please use sudo."))
        sys.exit(1)

    # Parse arguments
    args = parse_args()

    # Create test configuration
    config = TestConfig(
        args.test_dir,
        {
            'test_size': args.test_size,
            'db_file': args.db_file,
            'jobs': args.jobs,
            'runtime': args.time,
            'repeat': args.repeat
        }
    )

    # Create and run the stress tester
    tester = FSStressTester(config)
    tester.run()


if __name__ == "__main__":
    main()
