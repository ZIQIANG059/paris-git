#!/bin/bash
#set -x

./runtest.sh F height_test F 2 0.32 1e-20 1 16
./runtest.sh F height_test T 2 0.32 1e-20 1 16
./runtest.sh F height_test F 3 0.32 1e-20 1 16
./runtest.sh F height_test T 3 0.32 1e-20 1 16
./runtest.sh T height_test F 2 0.32 1e-20 1 16


#ismono=$1
#type=$2
#normup=$3
#cyldir=$4
#radius=$5
#precision=$6
#refinement=$7
#nx=$8