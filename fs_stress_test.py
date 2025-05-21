#!/usr/bin/env python3
# fs_stress_test.py - Simplified Filesystem Stress Tester (Linux only)
# This script runs high-stress filesystem tests for Linux systems
# It reports drive configuration details and stores results in SQLite

import os
import sys
import sqlite3
import subprocess
import shutil
import time
import re
import argparse
import numpy as np
from typing import Tuple, Optional


# ANSI color functions for consistent output
def red(text): return f"\033[0;31m{text}\033[0m"
def green(text): return f"\033[0;32m{text}\033[0m"
def yellow(text): return f"\033[0;33m{text}\033[0m"
def blue(text): return f"\033[0;36m{text}\033[0m"
def purple(text): return f"\033[0;35m{text}\033[0m"


class FSStressTester:
    """Simplified filesystem stress tester for Linux systems."""

    def __init__(self, test_dir: str, test_size: str = None, db_file: str = None, 
                 jobs: int = 4, runtime: int = 20, repeat: int = 2):
        """Initialize the filesystem stress tester with test parameters."""
        self.test_dir = os.path.abspath(test_dir)
        self.num_jobs = jobs           # Concurrent jobs
        self.runtime_each = runtime    # Runtime (seconds per test run)
        self.runs = repeat             # Times to repeat each test
        self.test_size = test_size
        self.db_file = db_file
        self.run_id = None
        self.physical_devices = []

        # Optimize process priority - requires root
        self._optimize_process_priority()

        # Set test size if not provided
        if not self.test_size:
            self._auto_size_test_file()

        # Set database location if not provided
        if not self.db_file:
            self.db_file = "/tmp/fs_benchmark.db"

        # Create test directory if it doesn't exist
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
            subprocess.run(['ionice', '-c', '1', '-n', '0', '-p', str(os.getpid())],
                         stderr=subprocess.DEVNULL)
            
            # Set highest CPU priority
            os.nice(-20)
            
            # Increase file descriptor limit
            import resource
            resource.setrlimit(resource.RLIMIT_NOFILE, (1048576, 1048576))
            
            print("Running with elevated process priority")
        except Exception as e:
            print(f"Warning: Unable to optimize process priority: {e}")

    def _auto_size_test_file(self) -> None:
        """Automatically size the test file based on available space."""
        try:
            # Check directory for space calculation
            check_dir = self.test_dir if os.path.exists(self.test_dir) else os.path.dirname(self.test_dir)

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
            # If auto-sizing fails, use a safe default
            self.test_size = "1G"
            print(f"Warning: Error auto-sizing test file: {e}. Using default size: {self.test_size}")

    def _get_cpu_info(self) -> str:
        """Get CPU information."""
        try:
            with open('/proc/cpuinfo', 'r') as f:
                for line in f:
                    if 'model name' in line:
                        return line.split(':', 1)[1].strip()
            return "Unknown CPU"
        except Exception:
            return "Unknown CPU"

    def _get_memory_info(self) -> str:
        """Get system memory information."""
        try:
            result = subprocess.run(['free', '-h'], capture_output=True, text=True)
            for line in result.stdout.split('\n'):
                if line.startswith('Mem:'):
                    return line.split()[1]
            return "Unknown"
        except Exception:
            return "Unknown"

    def _get_filesystem_type(self) -> str:
        """Get filesystem type for the test directory."""
        try:
            result = subprocess.run(
                ['df', '-Th', self.test_dir],
                capture_output=True,
                text=True
            )
            return result.stdout.strip().split('\n')[1].split()[1]
        except Exception:
            return "Unknown"

    def _get_mount_options(self) -> str:
        """Get mount options for the test directory."""
        try:
            mount_point = subprocess.run(
                ['df', '-P', self.test_dir],
                capture_output=True,
                text=True
            ).stdout.strip().split('\n')[1].split()[5]

            with open('/proc/mounts', 'r') as f:
                for line in f:
                    if mount_point in line:
                        return line.split()[3]
            return "Unknown"
        except Exception:
            return "Unknown"

    def init_database(self) -> None:
        """Initialize the SQLite database."""
        print(blue("Initializing benchmark database..."))

        try:
            conn = sqlite3.connect(self.db_file)
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

    def get_previous_results(self, test_name: str) -> Tuple[Optional[float], Optional[float], Optional[float]]:
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
            else:
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
                else:
                    return red(f"+{change:.2f}%")
            else:
                # For IOPS and bandwidth, positive change is good
                if change < 0:
                    return red(f"{change:.2f}%")
                else:
                    return green(f"+{change:.2f}%")
        except Exception:
            return "N/A"

    def get_storage_info(self) -> None:
        """Get basic information about the storage device."""
        print(blue("=== Storage Device Analysis ==="))

        try:
            # Get the mount point for the directory
            result = subprocess.run(['df', '-P', self.test_dir],
                                 capture_output=True, text=True, check=True)
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
                with open(rotational_path, 'r') as f:
                    if f.read().strip() == "0":
                        print(f"{yellow('Device type:')} SSD")
                    else:
                        print(f"{yellow('Device type:')} HDD (rotational)")
                        
            # Check I/O scheduler
            scheduler_path = f"/sys/block/{device_name}/queue/scheduler"
            if os.path.exists(scheduler_path):
                with open(scheduler_path, 'r') as f:
                    scheduler_data = f.read().strip()
                    match = re.search(r'\[(.*?)\]', scheduler_data)
                    if match:
                        print(f"{yellow('I/O scheduler:')} {match.group(1)}")
                    else:
                        print(f"{yellow('I/O scheduler:')} {scheduler_data}")
                        
        except Exception as e:
            print(red(f"Error detecting storage device: {e}"))

    def extract_metric(self, output: str, metric: str) -> Optional[float]:
        """Extract the specified metric from fio output."""
        try:
            if metric == "iops":
                # Look for IOPS value in fio output
                matches = re.search(r'iops\s*=\s*([0-9.]+)([kKMG]?)', output)
                if matches:
                    val = float(matches.group(1))
                    unit = matches.group(2).lower() if matches.group(2) else ''

                    if unit == 'k':
                        val *= 1000
                    elif unit == 'm':
                        val *= 1000000
                    elif unit == 'g':
                        val *= 1000000000

                    return val

                # Try newer fio format
                matches = re.search(r'IOPS\s*=\s*([0-9.]+)([kKMG]?)', output)
                if matches:
                    val = float(matches.group(1))
                    unit = matches.group(2).lower() if matches.group(2) else ''

                    if unit == 'k':
                        val *= 1000
                    elif unit == 'm':
                        val *= 1000000
                    elif unit == 'g':
                        val *= 1000000000

                    return val
                return 0

            elif metric == "lat":
                # Look for average latency
                matches = re.search(r'lat.*?avg\s*=\s*([0-9.]+)', output)
                if matches:
                    return float(matches.group(1))
                return 0

            elif metric == "bw":
                # Try newer fio format first (KiB/s)
                matches = re.search(r'bw\s*=\s*([0-9.]+)([kKMG]?)iB/s', output)
                if matches:
                    val = float(matches.group(1))
                    unit = matches.group(2).lower() if matches.group(2) else ''

                    if unit == 'k':
                        val *= 1024
                    elif unit == 'm':
                        val *= 1048576
                    elif unit == 'g':
                        val *= 1073741824

                    return val

                # Fallback to older format
                matches = re.search(r'bw\s*=\s*([0-9.]+)([kKMG]?)B/s', output)
                if matches:
                    val = float(matches.group(1))
                    unit = matches.group(2).lower() if matches.group(2) else ''

                    if unit == 'k':
                        val *= 1024
                    elif unit == 'm':
                        val *= 1048576
                    elif unit == 'g':
                        val *= 1073741824

                    return val

                return 0
            else:
                return None
        except Exception as e:
            print(red(f"Warning: Error extracting {metric}: {e}"))
            return 0

    def run_test(self, test_name: str, fio_options: str, description: str) -> None:
        """Run fio test multiple times and calculate geometric mean."""
        print(green(f"Running test: {test_name}"))
        print(f"{yellow('Description:')} {description}")

        # Arrays to store results
        results_iops = []
        results_lat = []
        results_bw = []

        # Drop caches before starting
        try:
            with open('/proc/sys/vm/drop_caches', 'w') as f:
                f.write('3')
            subprocess.run(['sync'], check=False)
        except Exception as e:
            print(red(f"Error dropping caches: {e}"))

        for run in range(1, self.runs + 1):
            print(blue(f"Run {run} of {self.runs}"))
            print(f"{yellow('Command:')} fio {self.ssd_params} {fio_options}")

            # Clear caches before each run
            try:
                with open('/proc/sys/vm/drop_caches', 'w') as f:
                    f.write('3')
                subprocess.run(['sync'], check=False)
            except Exception as e:
                print(red(f"Error dropping caches: {e}"))

            # Run fio with high priority
            try:
                cmd = ['ionice', '-c', '1', '-n', '0', 'nice', '-n', '-20',
                     'fio'] + self.ssd_params.split() + fio_options.split()

                # Run fio and capture output
                process = subprocess.run(cmd, capture_output=True, text=True, check=True)
                output = process.stdout

                # Extract metrics from the output
                iops = self.extract_metric(output, "iops")
                lat = self.extract_metric(output, "lat")
                bw = self.extract_metric(output, "bw")

                # Handle None values
                iops = 0 if iops is None else iops
                lat = 0 if lat is None else lat
                bw = 0 if bw is None else bw

                print(purple(f"Run {run} Results: IOPS={iops:.2f}, Latency={lat:.2f} ms, Bandwidth={bw:.2f} KB/s"))

                # Store results
                results_iops.append(iops)
                results_lat.append(lat)
                results_bw.append(bw)

                # Short pause between runs
                time.sleep(2)

            except subprocess.SubprocessError as e:
                print(red(f"Error running fio: {e}"))
                # Append zeros to maintain consistent arrays
                results_iops.append(0)
                results_lat.append(0)
                results_bw.append(0)

        # Calculate geometric means (filter out zeros and None values)
        valid_iops = [x for x in results_iops if x is not None and x > 0]
        valid_lat = [x for x in results_lat if x is not None and x > 0]
        valid_bw = [x for x in results_bw if x is not None and x > 0]

        if valid_iops:
            geomean_iops = float(np.exp(np.mean(np.log(valid_iops))))
        else:
            geomean_iops = 0

        if valid_lat:
            geomean_lat = float(np.exp(np.mean(np.log(valid_lat))))
        else:
            geomean_lat = 0

        if valid_bw:
            geomean_bw = float(np.exp(np.mean(np.log(valid_bw))))
        else:
            geomean_bw = 0

        # Save results to database
        self.save_test_results(test_name, geomean_iops, geomean_lat, geomean_bw)

        # Get previous results for comparison
        prev_iops, prev_latency, prev_bandwidth = self.get_previous_results(test_name)

        if prev_iops is not None:
            # Calculate percentage changes
            iops_change = self.calc_percentage_change(geomean_iops, prev_iops)
            lat_change = self.calc_percentage_change(geomean_lat, prev_latency, is_latency=True)
            bw_change = self.calc_percentage_change(geomean_bw, prev_bandwidth)

            # Print results with comparisons
            print("")
            print(green(f"=== Results for {test_name} (with comparison) ==="))
            print(f"{yellow('IOPS:')}             {geomean_iops:.2f} \t[Previous: {prev_iops:.2f} \tChange: {iops_change}]")
            print(f"{yellow('Average Latency:')}  {geomean_lat:.2f} ms \t[Previous: {prev_latency:.2f} ms \tChange: {lat_change}]")
            print(f"{yellow('Bandwidth:')}        {geomean_bw:.2f} KB/s \t[Previous: {prev_bandwidth:.2f} KB/s \tChange: {bw_change}]")
        else:
            # No previous results
            print("")
            print(green(f"=== Results for {test_name} ==="))
            print(f"{yellow('IOPS:')}             {geomean_iops:.2f}")
            print(f"{yellow('Average Latency:')}  {geomean_lat:.2f} ms")
            print(f"{yellow('Bandwidth:')}        {geomean_bw:.2f} KB/s")
            print(blue("(No previous test data available for comparison)"))

        print("")
        print(green(f"Completed test: {test_name}"))
        print("--------------------------------------------------------------")
        print("")

    def run_all_tests(self) -> None:
        """Run core filesystem stress tests."""
        # Display test parameters
        print(blue("=== Test Parameters ==="))
        print(f"{yellow('Test directory:')} {self.test_dir}")
        print(f"{yellow('Test size:')} {self.test_size}")
        print(f"{yellow('Number of jobs:')} {self.num_jobs}")
        print(f"{yellow('Runtime per test:')} {self.runtime_each} seconds")
        print(f"{yellow('Number of runs per test:')} {self.runs}")
        print(f"{yellow('Database file:')} {self.db_file}")
        print("")

        # Create an empty file to pre-allocate space
        print(blue("Pre-allocating test file..."))
        preallocated_file = os.path.join(self.test_dir, "preallocated_file")

        try:
            # Try fallocate first
            if shutil.which('fallocate'):
                size_arg = self.test_size
                subprocess.run(['fallocate', '-l', size_arg, preallocated_file], check=True)
            else:
                # Fallback to dd
                size_mb = 0
                if self.test_size.endswith('G'):
                    size_mb = int(float(self.test_size[:-1]) * 1024)
                elif self.test_size.endswith('M'):
                    size_mb = int(float(self.test_size[:-1]))
                else:
                    size_mb = 1024  # default to 1GB

                # Use dd to create the file
                subprocess.run([
                    'dd', 'if=/dev/zero', f'of={preallocated_file}',
                    'bs=1M', f'count={size_mb}', 'status=progress'
                ], check=True)
        except Exception as e:
            print(red(f"Warning: Error pre-allocating file: {e}"))
        print("")

        # 1. METADATA-INTENSIVE WORKLOAD
        self.run_test(
            "Metadata-Intensive",
            f"--directory={self.test_dir} --name=metadata_test --size=32M --nrfiles=1000 "
            f"--rw=randwrite --bs=4k --sync=1 --fsync=1 --runtime={self.runtime_each} "
            f"--time_based --numjobs={self.num_jobs} --group_reporting --iodepth=64 "
            f"--file_service_type=random --ramp_time=5",
            "Small files with synchronous writes, stressing filesystem metadata operations."
        )

        # 2. SYNCHRONOUS RANDOM WRITES
        self.run_test(
            "Random Writes",
            f"--directory={self.test_dir} --name=rand_write --size={self.test_size} "
            f"--rw=randwrite --bs=4k --sync=1 --runtime={self.runtime_each} "
            f"--time_based --numjobs={self.num_jobs} --group_reporting --iodepth=64",
            "Random write performance with synchronous I/O."
        )

        # 3. MIXED READ/WRITE WORKLOAD
        self.run_test(
            "Mixed ReadWrite",
            f"--directory={self.test_dir} --name=mixed_rw --size={self.test_size} "
            f"--rw=randrw --rwmixread=70 --bs=8k --runtime={self.runtime_each} "
            f"--time_based --numjobs={self.num_jobs} --group_reporting --iodepth=32",
            "Mixed read/write workload with 70% reads, typical of database environments."
        )

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
        """Run the full benchmark suite."""
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
    """Parse command-line arguments."""
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
    """Main entry point for the script."""
    # Check if running as root
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