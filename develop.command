#!/bin/zsh
git gc --prune=now --aggressive > round_status.txt 2>&1
rm -rf claw-code.*(N)
rm -rf xbenchTest
rm -rf llama.cpp.*(N)
git add -A
git branch -D dev
git branch dev
git checkout dev
git commit -m "Start new development round"
git push --set-upstream origin dev -f
git checkout main
git pull origin dev
git reset HEAD~1
source zshrc.zsh
diskcheck