#!/usr/bin/env python3
"""
Simple script to check basic Python code style issues in fs_stress_test.py
"""

import os
import sys
import re

def check_line_length(file_path, max_length=100):
    """Check if any lines exceed the maximum length."""
    with open(file_path, 'r', encoding='utf-8') as file:
        for line_num, line in enumerate(file, 1):
            if len(line.rstrip('\n')) > max_length:
                print(f"Line {line_num} exceeds {max_length} characters")

def check_naming_conventions(file_path):
    """Check if naming conventions follow PEP8."""
    with open(file_path, 'r', encoding='utf-8') as file:
        content = file.read()
        
        # Check class names (should be CamelCase)
        class_pattern = r'class\s+([a-zA-Z_][a-zA-Z0-9_]*)'
        for match in re.finditer(class_pattern, content):
            class_name = match.group(1)
            if not class_name[0].isupper() or '_' in class_name:
                print(f"Class name '{class_name}' should be CamelCase")
        
        # Check function names (should be snake_case)
        func_pattern = r'def\s+([a-zA-Z_][a-zA-Z0-9_]*)'
        for match in re.finditer(func_pattern, content):
            func_name = match.group(1)
            if func_name.startswith('__'):  # Skip dunder methods
                continue
            if any(c.isupper() for c in func_name):
                print(f"Function name '{func_name}' should be snake_case")

def check_imports(file_path):
    """Check imports order and grouping."""
    with open(file_path, 'r', encoding='utf-8') as file:
        lines = file.readlines()
        
        import_lines = []
        for i, line in enumerate(lines):
            if line.strip().startswith(('import ', 'from ')):
                import_lines.append((i, line.strip()))
        
        # Check if imports are at the beginning
        if import_lines and import_lines[0][0] > 10:  # Allow for docstrings and comments
            print("Imports should be at the top of the file")
        
        # Check for standard library vs. third-party imports
        stdlib_imports = []
        thirdparty_imports = []
        
        for _, imp in import_lines:
            module = imp.split()[1].split('.')[0]
            if module in sys.builtin_module_names or module in ('os', 'sys', 're', 'math', 'time', 'datetime'):
                stdlib_imports.append(imp)
            else:
                thirdparty_imports.append(imp)
        
        if stdlib_imports and thirdparty_imports:
            # Check if standard library imports come before third-party
            if import_lines.index((_, thirdparty_imports[0])) < import_lines.index((_, stdlib_imports[-1])):
                print("Standard library imports should come before third-party imports")

def check_docstrings(file_path):
    """Check if classes and functions have docstrings."""
    with open(file_path, 'r', encoding='utf-8') as file:
        content = file.read()
        
        # Check class docstrings
        class_pattern = r'class\s+([a-zA-Z_][a-zA-Z0-9_]*).*?:'
        for match in re.finditer(class_pattern, content):
            pos = match.end()
            next_lines = content[pos:pos+100].strip()
            if not (next_lines.startswith('"""') or next_lines.startswith("'''")):
                print(f"Class '{match.group(1)}' is missing a docstring")
        
        # Check function docstrings
        func_pattern = r'def\s+([a-zA-Z_][a-zA-Z0-9_]*).*?:'
        for match in re.finditer(func_pattern, content):
            pos = match.end()
            next_lines = content[pos:pos+100].strip()
            if not (next_lines.startswith('"""') or next_lines.startswith("'''")):
                print(f"Function '{match.group(1)}' is missing a docstring")

def main():
    """Run all checks on the specified file."""
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <file_path>")
        sys.exit(1)
    
    file_path = sys.argv[1]
    if not os.path.isfile(file_path):
        print(f"Error: File '{file_path}' does not exist.")
        sys.exit(1)
    
    print(f"Running code style checks on {file_path}...\n")
    
    check_line_length(file_path)
    check_naming_conventions(file_path)
    check_imports(file_path)
    check_docstrings(file_path)
    
    print("\nCode style check completed.")

if __name__ == "__main__":
    main()