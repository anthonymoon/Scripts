#!/usr/bin/env python3
"""
A comprehensive disk I/O stress tester focused on Linux systems.
Runs essential fio tests and stores results in SQLite database.
Includes storage device detection and comparison with previous runs.
"""

import os
import sys
import sqlite3
import subprocess
import time
import re
import argparse
import platform
import resource
import shutil
from statistics import geometric_mean
from typing import Dict, List, Literal, TypeAlias, Tuple, Optional, Any, Match as ReMatch, cast


# Type aliases for metrics
MetricName: TypeAlias = Literal["iops", "lat", "bw"]
MetricValue = float
ResultsDict = Dict[MetricName, List[MetricValue]]


# ANSI color codes
class Colors:
    """ANSI color codes for pretty output."""
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    CYAN = '\033[96m'
    PURPLE = '\033[35m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'
    END = '\033[0m'


class DiskStressTester:
    """Enhanced disk stress tester using fio."""

    def __init__(
        self,
        test_dir: str = './disk_test',
        test_size: str = '4G',
        db_file: str = 'disk_test.db',
        num_jobs: int = 4,
        runtime: int = 30,
        runs: int = 3
    ):
        """Initialize the disk stress tester with test parameters."""
        self.test_dir = os.path.abspath(test_dir)
        self.test_size = test_size
        self.db_file = db_file
        self.num_jobs = num_jobs
        self.runtime = runtime  # seconds per test
        self.runs = runs     # number of runs per test
        self.run_id: Optional[int] = None
        self.physical_devices: List[str] = []

        # Create test directory if needed
        os.makedirs(self.test_dir, exist_ok=True)

        # Optimize process priority - requires root
        self._optimize_process_priority()

        # Core fio parameters optimized for modern storage
        self.fio_params = (
            "--direct=1 --ioengine=libaio --name=fiotest "
            "--thread --verify=0 --norandommap"
        )

        # Display system information
        print(f"{Colors.BLUE}=== System Information ==={Colors.END}")
        print(f"{Colors.YELLOW}Kernel:{Colors.END} {os.uname().release}")
        print(f"{Colors.YELLOW}CPU:{Colors.END} {self._get_cpu_info()}")
        print(f"{Colors.YELLOW}Memory:{Colors.END} {self._get_memory_info()}")
        print(f"{Colors.YELLOW}Filesystem:{Colors.END} {self._get_filesystem_type()}")
        print(f"{Colors.YELLOW}Mount options:{Colors.END} {self._get_mount_options()}")
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
                ['df', '-Th', self.test_dir],
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
        except (subprocess.SubprocessError, IndexError, IOError) as err:
            print(f"Warning: Could not get mount options: {err}")
            return "Unknown"

    def init_database(self) -> None:
        """Initialize SQLite database with comprehensive schema."""
        print(f"{Colors.BLUE}Initializing benchmark database...{Colors.END}")
        
        try:
            conn = sqlite3.connect(self.db_file)
            cursor = conn.cursor()

            # Create tables if they don't exist
            cursor.execute('''
            CREATE TABLE IF NOT EXISTS test_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                kernel_version TEXT,
                cpu_info TEXT,
                filesystem_type TEXT,
                mount_options TEXT,
                test_dir TEXT NOT NULL,
                test_size TEXT NOT NULL,
                num_jobs INTEGER NOT NULL,
                run_time INTEGER NOT NULL
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

            cursor.execute('''
            CREATE TABLE IF NOT EXISTS device_info (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id INTEGER NOT NULL,
                device_path TEXT NOT NULL,
                device_type TEXT,
                write_cache TEXT,
                ncq_status TEXT,
                io_scheduler TEXT,
                readahead_kb TEXT,
                FOREIGN KEY (run_id) REFERENCES test_runs(id)
            )
            ''')

            conn.commit()
            conn.close()
            db_path = f"{Colors.CYAN}{self.db_file}"
            msg = f"Database initialized: {db_path}"
            print(f"{Colors.GREEN}{msg}{Colors.END}")
        except sqlite3.Error as e:
            error_msg = "Error initializing database:"
            print(f"{Colors.RED}{error_msg} {e}{Colors.END}")
            sys.exit(1)

    def save_run_metadata(self) -> None:
        """Save run metadata to database and get the run_id."""
        print(f"{Colors.BLUE}Saving run metadata to database...{Colors.END}")

        try:
            kernel = os.uname().release
            cpu_info = self._get_cpu_info()
            fs_type = self._get_filesystem_type()
            mount_opts = self._get_mount_options()

            conn = sqlite3.connect(self.db_file)
            cursor = conn.cursor()

            cursor.execute('''
            INSERT INTO test_runs
                (timestamp, kernel_version, cpu_info, filesystem_type, 
                 mount_options, test_dir, test_size, num_jobs, run_time)
            VALUES
                (datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (kernel, cpu_info, fs_type, mount_opts, self.test_dir, 
                  self.test_size, self.num_jobs, self.runtime))

            self.run_id = cast(int, cursor.lastrowid)
            conn.commit()
            conn.close()

            print(f"Run metadata saved with ID: {self.run_id}")
        except sqlite3.Error as err:
            print(f"{Colors.RED}Error saving run metadata: {err}{Colors.END}")
            sys.exit(1)

    def save_device_info(self, device: str, device_type: str, write_cache: str,
                        ncq_status: str, io_scheduler: str, readahead: str) -> None:
        """Save device info to database."""
        try:
            conn = sqlite3.connect(self.db_file)
            cursor = conn.cursor()

            cursor.execute('''
            INSERT INTO device_info 
                (run_id, device_path, device_type, write_cache, ncq_status, 
                 io_scheduler, readahead_kb)
            VALUES 
                (?, ?, ?, ?, ?, ?, ?)
            ''', (self.run_id, device, device_type, write_cache, ncq_status,
                 io_scheduler, readahead))

            conn.commit()
            conn.close()
        except sqlite3.Error as err:
            print(f"{Colors.RED}Warning: Could not save device info: {err}{Colors.END}")

    def save_results(
        self,
        test_name: str,
        iops: MetricValue,
        latency: MetricValue,
        bandwidth: MetricValue
    ) -> None:
        """Save test results to database."""
        try:
            # Use 0.0 for None or empty values
            iops_val = float(iops) if iops is not None else 0.0
            latency_val = float(latency) if latency is not None else 0.0
            bandwidth_val = float(bandwidth) if bandwidth is not None else 0.0
            
            conn = sqlite3.connect(self.db_file)
            cursor = conn.cursor()

            cursor.execute('''
            INSERT INTO test_results
                (run_id, test_name, iops, latency_ms, bandwidth_kbs)
            VALUES
                (?, ?, ?, ?, ?)
            ''', (self.run_id, test_name, iops_val, latency_val, bandwidth_val))

            conn.commit()
            conn.close()
        except sqlite3.Error as e:
            print(f"{Colors.RED}Warning: Could not save results: {e}{Colors.END}")

    def get_previous_results(self, test_name: str) -> Tuple[
            Optional[float], Optional[float], Optional[float]]:
        """Get the previous run's results for comparison."""
        try:
            conn = sqlite3.connect(self.db_file)
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
            print(f"{Colors.RED}Warning: Could not get previous results: {err}{Colors.END}")
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
                    return f"{Colors.GREEN}{change:.2f}%{Colors.END}"
                return f"{Colors.RED}+{change:.2f}%{Colors.END}"

            # For IOPS and bandwidth, positive change is good
            if change < 0:
                return f"{Colors.RED}{change:.2f}%{Colors.END}"
            return f"{Colors.GREEN}+{change:.2f}%{Colors.END}"
        except (ValueError, ZeroDivisionError, TypeError) as err:
            print(f"Warning: Error calculating percentage change: {err}")
            return "N/A"

    @staticmethod
    def format_bandwidth(bandwidth_kbs: MetricValue) -> str:
        """Format bandwidth in the most appropriate unit."""
        if bandwidth_kbs >= 1024 * 1024:  # >= 1 GB/s
            return f"{bandwidth_kbs / (1024 * 1024):.2f} GB/s"
        elif bandwidth_kbs >= 1024:  # >= 1 MB/s
            return f"{bandwidth_kbs / 1024:.2f} MB/s"
        else:  # < 1 MB/s
            return f"{bandwidth_kbs:.2f} KB/s"

    @staticmethod
    def format_iops(iops: MetricValue) -> str:
        """Format IOPS in the most appropriate unit."""
        if iops >= 1_000_000:  # >= 1M IOPS
            return f"{iops / 1_000_000:.2f}M IOPS"
        elif iops >= 1000:  # >= 1K IOPS
            return f"{iops / 1000:.2f}K IOPS"
        else:  # < 1K IOPS
            return f"{iops:.2f} IOPS"

    def get_storage_info(self) -> None:
        """Get basic information about the storage device.

        Identifies the physical storage device hosting the test directory,
        determines if it's an SSD or HDD, and checks the active I/O scheduler.
        Prints this information to the console.
        """
        print(f"{Colors.BLUE}=== Storage Device Analysis ==={Colors.END}")

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
            print(f"{Colors.YELLOW}Storage device:{Colors.END} {fs_device}")
            self.physical_devices.append(fs_device)

            # Try to determine if it's an SSD
            device_name = os.path.basename(fs_device)
            if re.match(r'^[a-zA-Z]+[0-9]+$', device_name):
                device_name = re.sub(r'[0-9]+$', '', device_name)

            rotational_path = f"/sys/block/{device_name}/queue/rotational"
            if os.path.exists(rotational_path):
                with open(rotational_path, 'r', encoding='utf-8') as f:
                    if f.read().strip() == "0":
                        print(f"{Colors.YELLOW}Device type:{Colors.END} SSD")
                    else:
                        print(f"{Colors.YELLOW}Device type:{Colors.END} HDD (rotational)")

            # Check I/O scheduler
            scheduler_path = f"/sys/block/{device_name}/queue/scheduler"
            if os.path.exists(scheduler_path):
                with open(scheduler_path, 'r', encoding='utf-8') as f:
                    scheduler_data = f.read().strip()
                    match = re.search(r'\[(.*?)\]', scheduler_data)
                    if match:
                        print(f"{Colors.YELLOW}I/O scheduler:{Colors.END} {match.group(1)}")
                    else:
                        print(f"{Colors.YELLOW}I/O scheduler:{Colors.END} {scheduler_data}")

            # Check device parameters (write cache, NCQ, etc)
            self.check_device_params(fs_device)

        except (subprocess.SubprocessError, ValueError, IOError) as err:
            print(f"{Colors.RED}Error detecting storage device: {err}{Colors.END}")

    def check_device_params(self, device: str) -> None:
        """Check device parameters (write cache, NCQ, scheduler, readahead)."""
        # Convert partition (e.g., /dev/sda1) to disk device (e.g., /dev/sda)
        if re.match(r'^/dev/[a-zA-Z]+[0-9]+$', device):
            block_device = re.sub(r'[0-9]+$', '', device)
        else:
            block_device = device
        
        # Get just the device name without /dev/
        short_name = os.path.basename(block_device)
        
        print(f"{Colors.BLUE}Device parameters for {device}:{Colors.END}")
        
        # Check if device is an SSD
        is_ssd = 0
        device_type = "Unknown"
        if os.path.exists(f"/sys/block/{short_name}"):
            if os.path.exists(f"/sys/block/{short_name}/queue/rotational"):
                with open(f"/sys/block/{short_name}/queue/rotational", 'r', encoding='utf-8') as f:
                    if f.read().strip() == "0":
                        print(f"{Colors.YELLOW}Device type:{Colors.END} SSD")
                        is_ssd = 1
                        device_type = "SSD"
                    else:
                        print(f"{Colors.YELLOW}Device type:{Colors.END} HDD (rotational)")
                        device_type = "HDD (rotational)"
        
        # Check write cache status
        write_cache_status = "Unknown"
        cache_path = f"/sys/block/{short_name}/device/scsi_disk/{short_name}/cache_type"
        if os.path.exists(cache_path):
            with open(cache_path, 'r', encoding='utf-8') as f:
                write_cache_status = f.read().strip()
            print(f"{Colors.YELLOW}Write cache:{Colors.END} {write_cache_status}")
        elif os.path.exists(f"/sys/block/{short_name}/device/write_cache"):
            with open(f"/sys/block/{short_name}/device/write_cache", 'r', encoding='utf-8') as f:
                write_cache = f.read().strip()
            if write_cache == "1":
                write_cache_status = "Enabled"
                print(f"{Colors.YELLOW}Write cache:{Colors.END} Enabled")
            else:
                write_cache_status = "Disabled"
                print(f"{Colors.YELLOW}Write cache:{Colors.END} Disabled")
        elif shutil.which('hdparm'):
            try:
                result = subprocess.run(
                    ['hdparm', '-W', block_device],
                    capture_output=True,
                    text=True,
                    check=False
                )
                for line in result.stdout.split('\n'):
                    if "write-caching" in line:
                        write_cache_status = line.strip()
                        print(f"{Colors.YELLOW}Write cache (via hdparm):{Colors.END} {line.strip()}")
                        break
            except subprocess.SubprocessError:
                pass
        else:
            print(f"{Colors.YELLOW}Write cache:{Colors.END} Unable to determine")
        
        # Check NCQ status for SATA devices
        ncq_status = "Unknown"
        if is_ssd:
            queue_path = f"/sys/block/{short_name}/device/queue_depth"
            if os.path.exists(queue_path):
                with open(queue_path, 'r', encoding='utf-8') as f:
                    queue_depth = f.read().strip()
                if int(queue_depth) > 1:
                    ncq_status = f"Enabled (queue depth: {queue_depth})"
                    print(f"{Colors.YELLOW}NCQ:{Colors.END} Enabled (queue depth: {queue_depth})")
                else:
                    ncq_status = "Disabled"
                    print(f"{Colors.YELLOW}NCQ:{Colors.END} Disabled")
            elif shutil.which('smartctl'):
                try:
                    result = subprocess.run(
                        ['smartctl', '-i', block_device],
                        capture_output=True,
                        text=True,
                        check=False
                    )
                    for line in result.stdout.split('\n'):
                        if "NCQ" in line:
                            ncq_status = line.strip()
                            print(f"{Colors.YELLOW}NCQ (via smartctl):{Colors.END} {line.strip()}")
                            break
                except subprocess.SubprocessError:
                    pass
            else:
                print(f"{Colors.YELLOW}NCQ:{Colors.END} Unable to determine")
        
        # Check I/O scheduler
        io_scheduler = "Unknown"
        scheduler_path = f"/sys/block/{short_name}/queue/scheduler"
        if os.path.exists(scheduler_path):
            with open(scheduler_path, 'r', encoding='utf-8') as f:
                scheduler_data = f.read().strip()
            match = re.search(r'\[(.*?)\]', scheduler_data)
            if match:
                io_scheduler = match.group(1)
                print(f"{Colors.YELLOW}I/O scheduler:{Colors.END} {io_scheduler}")
            else:
                io_scheduler = scheduler_data
                print(f"{Colors.YELLOW}I/O scheduler:{Colors.END} {io_scheduler}")
        else:
            print(f"{Colors.YELLOW}I/O scheduler:{Colors.END} Unable to determine")
        
        # Check readahead setting
        readahead = "Unknown"
        readahead_path = f"/sys/block/{short_name}/queue/read_ahead_kb"
        if os.path.exists(readahead_path):
            with open(readahead_path, 'r', encoding='utf-8') as f:
                readahead = f.read().strip()
            print(f"{Colors.YELLOW}Readahead:{Colors.END} {readahead} KB")
        elif shutil.which('blockdev'):
            try:
                result = subprocess.run(
                    ['blockdev', '--getra', block_device],
                    capture_output=True,
                    text=True,
                    check=False
                )
                readahead = f"{result.stdout.strip()} KB"
                print(f"{Colors.YELLOW}Readahead (via blockdev):{Colors.END} {result.stdout.strip()} KB")
            except subprocess.SubprocessError:
                pass
        else:
            print(f"{Colors.YELLOW}Readahead:{Colors.END} Unable to determine")
        
        # Check for NVMe devices
        if short_name.startswith('nvme'):
            print(f"{Colors.YELLOW}NVMe device details:{Colors.END}")
            if shutil.which('nvme'):
                try:
                    result = subprocess.run(
                        ['nvme', 'list'],
                        capture_output=True,
                        text=True,
                        check=False
                    )
                    for line in result.stdout.split('\n'):
                        if block_device in line:
                            print(line)
                            # Update device type
                            device_type = "NVMe SSD"
                            break
                except subprocess.SubprocessError:
                    print("  NVMe tools not available")
            else:
                print("  NVMe tools not available")
        
        # Save device info to database if we have a run_id
        if self.run_id is not None:
            self.save_device_info(device, device_type, write_cache_status, 
                                 ncq_status, io_scheduler, readahead)
        
        print("")

    def _convert_units(self, matches: ReMatch[str], binary: bool = False) -> float:
        """Convert units from K/M/G to base numbers."""
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

    def extract_metric(self, output: str, metric: MetricName) -> MetricValue:
        """Extract metrics from fio output using simplified patterns."""
        try:
            # Handle different metric types
            if metric == "iops":
                return self._extract_iops(output)
            if metric == "lat":
                return self._extract_latency(output)
            if metric == "bw":
                return self._extract_bandwidth(output)
            return 0.0
        except (ValueError, TypeError, AttributeError) as err:
            print(f"{Colors.RED}Warning: Error extracting {metric}: {err}{Colors.END}")
            return 0.0

    def _extract_iops(self, output: str) -> float:
        """Extract IOPS value from fio output."""
        # First try standard format
        matches = re.search(r'iops\s*=\s*([0-9.]+)([kKMG]?)', output)
        if matches:
            return self._convert_units(matches)

        # Try newer fio format
        matches = re.search(r'IOPS\s*=\s*([0-9.]+)([kKMG]?)', output)
        if matches:
            return self._convert_units(matches)

        return 0.0

    def _extract_latency(self, output: str) -> float:
        """Extract latency value from fio output."""
        matches = re.search(r'lat.*?avg\s*=\s*([0-9.]+)', output)
        if matches:
            return float(matches.group(1))
        return 0.0

    def _extract_bandwidth(self, output: str) -> float:
        """Extract bandwidth value from fio output."""
        # Try newer fio format first (KiB/s)
        matches = re.search(r'bw\s*=\s*([0-9.]+)([kKMG]?)iB/s', output)
        if matches:
            return self._convert_units(matches, binary=True) / 1024  # Convert to KB/s

        # Fallback to older format
        matches = re.search(r'bw\s*=\s*([0-9.]+)([kKMG]?)B/s', output)
        if matches:
            return self._convert_units(matches, binary=False) / 1024  # Convert to KB/s

        # Try different bandwidth patterns that fio might output
        patterns = [
            r'BW=\s*([0-9.]+)([kKMG]?)iB/s',
            r'bw=\s*([0-9.]+)([kKMG]?)B/s',
            r'READ:.+bw=([0-9.]+)([kKMG]?)B/s',
            r'WRITE:.+bw=([0-9.]+)([kKMG]?)B/s',
        ]

        for pattern in patterns:
            matches = re.search(pattern, output, re.IGNORECASE)
            if matches:
                val = float(matches.group(1))
                unit = matches.group(2).lower() if matches.group(2) else ''
                multipliers = {'k': 1024, 'm': 1048576, 'g': 1073741824}
                multiplier = multipliers.get(unit, 1)
                return val * multiplier / 1024  # Convert to KB/s
                
        return 0.0

    def drop_caches(self) -> None:
        """Drop system caches to ensure consistent benchmarking."""
        try:
            # Flush caches before test
            subprocess.run(['sync'], check=False)
            with open('/proc/sys/vm/drop_caches', 'w', encoding='utf-8') as f:
                f.write('3')
        except (IOError, subprocess.SubprocessError) as err:
            print(f"{Colors.RED}Error dropping caches: {err}{Colors.END}")

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
            formatted_bw = self.format_bandwidth(geomean_bw)
            # prev_bandwidth is not None at this point but we need the explicit check
            if prev_bandwidth is not None:
                formatted_prev_bw = self.format_bandwidth(prev_bandwidth)
            else:
                formatted_prev_bw = "0.00 KB/s"
            # Print results with comparisons
            title = f"=== Results for {test_name} (with comparison) ==="
            print(f"{Colors.GREEN}{title}{Colors.END}")
            print(f"{Colors.YELLOW}IOPS:{Colors.END} {self.format_iops(geomean_iops)} \t[Previous: {self.format_iops(prev_iops)} "
                  f"\tChange: {iops_change}]")
            print(f"{Colors.YELLOW}Latency:{Colors.END} {geomean_lat:.2f} ms \t"
                  f"[Previous: {prev_latency:.2f} ms \tChange: {lat_change}]")
            print(f"{Colors.YELLOW}Bandwidth:{Colors.END} {formatted_bw} \t"
                  f"[Previous: {formatted_prev_bw} \tChange: {bw_change}]")
        else:
            # No previous results
            formatted_bw = self.format_bandwidth(geomean_bw)
            title = f"=== Results for {test_name} ==="
            print(f"{Colors.GREEN}{title}{Colors.END}")
            print(f"{Colors.YELLOW}IOPS:{Colors.END} {self.format_iops(geomean_iops)}")
            print(f"{Colors.YELLOW}Latency:{Colors.END} {geomean_lat:.2f} ms")
            print(f"{Colors.YELLOW}Bandwidth:{Colors.END} {formatted_bw}")
            print(f"{Colors.BLUE}(No previous test data available for comparison){Colors.END}")

    def run_test(self, test_name: str, fio_options: str, description: str = "") -> None:
        """Run a single fio test multiple times."""
        title = f"Running test: {test_name}"
        print(f"\n{Colors.HEADER}{Colors.BOLD}{title}{Colors.END}")
        if description:
            print(f"{Colors.BLUE}Description: {description}{Colors.END}")

        results: ResultsDict = {
            "iops": [],
            "lat": [],
            "bw": []
        }

        # Drop caches before starting
        self.drop_caches()

        # Run test multiple times
        for run in range(1, self.runs + 1):
            print(f"\n{Colors.YELLOW}Run {run} of {self.runs}{Colors.END}")
            print(f"{Colors.YELLOW}Command:{Colors.END} fio {self.fio_params} {fio_options}")

            # Clear caches before each run
            self.drop_caches()

            try:
                # Run fio test with proper priority settings
                cmd = ['ionice', '-c', '1', '-n', '0', 'nice', '-n', '-20', 
                       'fio'] + self.fio_params.split() + fio_options.split()
                
                # Fallback if priority setting fails
                if shutil.which('ionice') is None or shutil.which('nice') is None:
                    cmd = ['fio'] + self.fio_params.split() + fio_options.split()
                
                cmd_str = ' '.join(cmd)
                print(f"{Colors.CYAN}Running command: {cmd_str}{Colors.END}")

                process = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    check=False
                )

                if process.returncode != 0:
                    print(f"{Colors.RED}fio stdout:{Colors.END}")
                    print(process.stdout)
                    print(f"{Colors.RED}fio stderr:{Colors.END}")
                    print(process.stderr)
                    msg = f"fio command failed with code {process.returncode}"
                    raise subprocess.SubprocessError(msg)

                output = process.stdout

                # Extract metrics
                metrics = ("iops", "lat", "bw")
                for metric in metrics:
                    value = self.extract_metric(output, metric)  # type: ignore[arg-type]
                    results[metric].append(value)

                print(f"{Colors.GREEN}Run {run} Results:{Colors.END}")
                print(f"{Colors.CYAN}IOPS:{Colors.END} {self.format_iops(results['iops'][-1])}")
                print(f"{Colors.CYAN}Latency:{Colors.END} {results['lat'][-1]:.2f} ms")
                bw_str = self.format_bandwidth(results['bw'][-1])
                print(f"{Colors.CYAN}Bandwidth:{Colors.END} {bw_str}")

                time.sleep(2)  # Brief pause between runs

            except subprocess.SubprocessError as e:
                print(f"{Colors.RED}Error running test: {e}{Colors.END}")
                for metric, metric_list in results.items():
                    metric_list.append(0.0)

        # Calculate geometric means
        geomean_results: Dict[MetricName, MetricValue] = {}
        for metric, values in results.items():
            nonzero_values: List[MetricValue] = [x for x in values if x > 0]
            geomean_results[metric] = (
                geometric_mean(nonzero_values) if nonzero_values else 0.0
            )

        # Save results
        self.save_results(
            test_name,
            geomean_results['iops'],
            geomean_results['lat'],
            geomean_results['bw']
        )

        # Get previous results and display
        prev_metrics = self.get_previous_results(test_name)
        self.display_results(test_name, 
                            (geomean_results['iops'], geomean_results['lat'], geomean_results['bw']), 
                            prev_metrics)

        print("")
        print(f"{Colors.GREEN}Completed test: {test_name}{Colors.END}")
        print("--------------------------------------------------------------")
        print("")

    def pre_allocate_file(self) -> str:
        """Pre-allocate test file and return its path."""
        print(f"{Colors.BLUE}Pre-allocating test file...{Colors.END}")
        preallocated_file = os.path.join(self.test_dir, "preallocated_file")

        try:
            # Try fallocate first (more efficient)
            if shutil.which('fallocate') and self.test_size is not None:
                subprocess.run(
                    ['fallocate', '-l', self.test_size, preallocated_file],
                    check=True
                )
                return preallocated_file

            # Convert size to MB for dd
            size_mb = 1024  # default 1GB
            if self.test_size is not None:
                if self.test_size.endswith('G'):
                    size_mb = int(float(self.test_size[:-1]) * 1024)
                elif self.test_size.endswith('M'):
                    size_mb = int(float(self.test_size[:-1]))

            # Use dd as fallback
            subprocess.run([
                'dd', 'if=/dev/zero', f'of={preallocated_file}',
                'bs=1M', f'count={size_mb}', 'status=progress'
            ], check=True)

        except (subprocess.SubprocessError, ValueError) as err:
            print(f"{Colors.RED}Warning: Error pre-allocating file: {err}{Colors.END}")

        return preallocated_file

    def display_test_parameters(self) -> None:
        """Display test parameters at the beginning of test run."""
        print(f"{Colors.BLUE}=== Test Parameters ==={Colors.END}")
        print(f"{Colors.YELLOW}Test directory:{Colors.END} {self.test_dir}")
        print(f"{Colors.YELLOW}Test size:{Colors.END} {self.test_size}")
        print(f"{Colors.YELLOW}Number of jobs:{Colors.END} {self.num_jobs}")
        print(f"{Colors.YELLOW}Runtime per test:{Colors.END} {self.runtime} seconds")
        print(f"{Colors.YELLOW}Number of runs per test:{Colors.END} {self.runs}")
        print(f"{Colors.YELLOW}Database file:{Colors.END} {self.db_file}")
        print("")

    def run_all_tests(self) -> None:
        """Run core set of disk stress tests."""
        header = f"Starting disk stress tests in {self.test_dir}"
        print(f"{Colors.HEADER}{Colors.BOLD}{header}{Colors.END}")
        
        # Display test parameters
        self.display_test_parameters()

        # Create an empty file to pre-allocate space
        preallocated_file = self.pre_allocate_file()
        print("")

        # Define common parameters
        base_opts = f"--time_based --numjobs={self.num_jobs} --group_reporting"

        # Define test configurations
        tests = [
            (
                "Random Write",
                (f"--directory={self.test_dir} --size={self.test_size} "
                 f"--rw=randwrite --bs=4k --runtime={self.runtime} "
                 f"--time_based --numjobs={self.num_jobs} "
                 f"--group_reporting --iodepth=32"),
                "Tests small random write performance"
            ),
            (
                "Random Read",
                (f"--directory={self.test_dir} --size={self.test_size} "
                 f"--rw=randread --bs=4k --runtime={self.runtime} "
                 f"--time_based --numjobs={self.num_jobs} "
                 f"--group_reporting --iodepth=32"),
                "Tests small random read performance"
            ),
            (
                "Mixed ReadWrite",
                (f"--directory={self.test_dir} --size={self.test_size} "
                 f"--rw=randrw --rwmixread=70 --bs=8k --runtime={self.runtime} "
                 f"--time_based --numjobs={self.num_jobs} "
                 f"--group_reporting --iodepth=32"),
                "Tests mixed read/write workload (70% reads, 30% writes)"
            ),
            (
                "Sequential Write",
                (f"--directory={self.test_dir} --size={self.test_size} "
                 f"--rw=write --bs=1M --runtime={self.runtime} "
                 f"--time_based --numjobs={self.num_jobs} "
                 f"--group_reporting --iodepth=16"),
                "Tests large sequential write performance"
            ),
            (
                "Metadata-Intensive",
                (f"--directory={self.test_dir} --name=metadata_test --size=32M "
                 f"--nrfiles=1000 --rw=randwrite --bs=4k --sync=1 --fsync=1 "
                 f"--runtime={self.runtime} {base_opts} "
                 f"--iodepth=64 --file_service_type=random --ramp_time=5"),
                "Small files with synchronous writes, testing metadata operations."
            ),
            (
                "FSyncHeavyWorkload",
                (f"--directory={self.test_dir} --name=fsync_heavy --size={self.test_size} "
                 f"--rw=write --bs=4k --fsync=8 --runtime={self.runtime} "
                 f"{base_opts} --iodepth=32 --ramp_time=5"),
                "Simulates a database-like workload with frequent fsync operations."
            ),
        ]

        # Run each test
        for test_name, fio_options, description in tests:
            self.run_test(test_name, fio_options, description)

        # Clean up
        print(f"{Colors.BLUE}Cleaning up test files...{Colors.END}")
        try:
            os.remove(preallocated_file)
        except OSError:
            pass

        # Ensure all data is flushed to disk
        subprocess.run(['sync'], check=False)

        # Final summary
        print("")
        print(f"{Colors.GREEN}{Colors.BOLD}All tests completed!{Colors.END}")
        print(f"Test results have been saved to the database at: {self.db_file}")
        print("")
        if self.run_id is not None:
            query = f"SELECT * FROM test_results WHERE run_id = {self.run_id}"
            print(f"To view results: sqlite3 {self.db_file} '{query};'")

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


def main():
    """Main function to run disk stress tests."""
    parser = argparse.ArgumentParser(
        description='Enhanced Disk I/O stress tester using fio',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument(
        '--test-dir',
        default='./disk_test',
        help='Directory where test files will be created'
    )
    parser.add_argument(
        '--test-size',
        default='4G',
        help='Size of test files (e.g., 4G, 10G)'
    )
    parser.add_argument(
        '--db-file',
        default='disk_test.db',
        help='SQLite database file to store results'
    )
    parser.add_argument(
        '-j', '--jobs',
        type=int,
        default=4,
        help='Number of concurrent jobs'
    )
    parser.add_argument(
        '-t', '--time',
        type=int,
        default=30,
        help='Runtime in seconds for each test'
    )
    parser.add_argument(
        '-r', '--repeat',
        type=int,
        default=3,
        help='Number of times to repeat each test'
    )
    args = parser.parse_args()

    # Check if running as root
    if os.geteuid() != 0:
        msg = "This script must be run as root to flush caches and set priorities"
        print(f"{Colors.RED}{msg}{Colors.END}")
        sys.exit(1)

    # Check if fio is installed
    try:
        subprocess.run(['which', 'fio'], capture_output=True, check=True)
    except subprocess.SubprocessError:
        print(f"{Colors.RED}Error: fio is not installed. Please install it first.")
        print(f"{Colors.YELLOW}On Debian/Ubuntu: apt-get install fio")
        print(f"On RHEL/CentOS: yum install fio{Colors.END}")
        sys.exit(1)

    # Create and run tester with command line arguments
    tester = DiskStressTester(
        test_dir=args.test_dir,
        test_size=args.test_size,
        db_file=args.db_file,
        num_jobs=args.jobs,
        runtime=args.time,
        runs=args.repeat
    )
    tester.run()

if __name__ == '__main__':
    main()