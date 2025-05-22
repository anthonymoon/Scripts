#!/bin/bash
# maintenance_script.sh
# Regular maintenance script for keeping home directory organized

echo "===== Home Directory Maintenance Script ====="

# 1. Delete .DS_Store files
echo "Deleting .DS_Store files..."
find ~ -name ".DS_Store" -type f -delete
echo "✅ Deleted .DS_Store files"

# 2. Empty Screenshots directory
echo "Emptying Screenshots directory..."
if [ -d ~/Screenshots ]; then
  rm -rf ~/Screenshots/*
  echo "✅ Screenshots directory emptied"
else
  echo "❌ Screenshots directory not found"
fi

# 3. Fix file system permissions
echo "Fixing file system permissions..."
find ~/Projects -type d -exec chmod 755 {} \; 2>/dev/null
find ~/Projects -type f -exec chmod 644 {} \; 2>/dev/null
find ~/Documents -type d -exec chmod 755 {} \; 2>/dev/null
find ~/Documents -type f -exec chmod 644 {} \; 2>/dev/null
echo "✅ Fixed permissions on Projects and Documents"

# 4. Make scripts executable
echo "Making scripts executable..."
find ~/Projects -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null
find ~/Projects -name "*.py" -type f -exec chmod +x {} \; 2>/dev/null
echo "✅ Made scripts executable"

# 5. Update dotfiles repository
echo "Updating dotfiles repository..."
if [ -d ~/dotfiles ] && [ -d ~/dotfiles/.git ]; then
  cd ~/dotfiles
  # Copy current dotfiles
  cp ~/.zshrc ~/dotfiles/ 2>/dev/null || echo "No .zshrc file"
  cp ~/.p10k.zsh ~/dotfiles/ 2>/dev/null || echo "No .p10k.zsh file"
  cp ~/.aliases ~/dotfiles/ 2>/dev/null || echo "No .aliases file"
  cp ~/.gitconfig ~/dotfiles/ 2>/dev/null || echo "No .gitconfig file"
  
  # Commit changes if any
  if git status --porcelain | grep -q .; then
    git add .
    git commit -m "Update dotfiles - Fri 16 May 2025 15:48:32 PDT"
    echo "Would you like to push changes to remote? (y/n)"
    read response
    if [[ "" =~ ^[Yy]$ ]]; then
      git push
      echo "✅ Pushed dotfiles to
# 4. Make scripts executable
echo "Makinggesecho "Making scripts execut  find ~/Projects -name "*.sh" -typehafind ~/Projects -name "*.py" -type f -exec chmod +x {} \; 2>/dev/nul
 echo "✅ Made scripts executable"

# 5. Update dotfilecat >> ~/maintenance_script.sh << EOFSCRIPT

# 6. Archive old files (not accessed in 180 days)
echo "Would you like to archive old files not accessed in 180 days? (y/n)"
read response
if [[ "" =~ ^[Yy]$ ]]; then
  echo "Archiving old files..."
  ARCHIVE_DIR=~/Archive/2025-05-16
  mkdir -p 
  
  # Find and move old files
  find ~ -type f -not -path "*/\.*" -not -path "*/Library/*" -not -path "*/Archive/*" -atime +180 -exec mv {} / \; 2>/dev/null
  
  echo "✅ Old files archived to "
else
  echo "⏭️  Skipping archive operation"
fi

# 7. Clean up broken symlinks
echo "Cleaning up broken symlinks..."
find ~ -type l -not -path "*/\.*" -not -path "*/Library/*" ! -exec test -e {} \; -delete 2>/dev/null
echo "✅ Removed broken symlinks"

# 8. Check disk space
echo "Checking disk space..."
df -h ~ | grep -v Filesystem

echo "===== Maintenance Complete ====="
echo "Your home directory has been cleaned and organized! 🎉"
