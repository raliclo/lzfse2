#!/bin/zsh

source ~/proj/lzfse2/zshrc.zsh
source ~/proj/lzfse2/lz4bench.zsh   # diskcheck 住在這裡 / diskcheck lives here

while true;do
date;tail /Users/raliclo/proj/git_push.log;diskcheck;sleep 60
done