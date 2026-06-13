#!/bin/zsh
# R9：對 claw-code optimal 壓縮取樣，找出真熱點 / Sample the optimal encoder
cd /Users/raliclo/proj/lzfse2 || exit 1
echo "PROFILING optimal $(date +%H:%M:%S)" > profile_status.txt
tar -cf - claw-code | ./lzfse -encode -si -o /dev/null -algo bvx3 -optimal &
LZPID=$!
sleep 8
SPID=$(pgrep -n lzfse)
sample $SPID 20 -file profile-optimal.txt 2>> profile_status.txt
wait $LZPID
echo "PROF_DONE $(date +%H:%M:%S)" >> profile_status.txt
exit 0
