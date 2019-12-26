#!/bin/bash

# Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

NOW=$(date +%s)

function log(){
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1"
}

if [[ ! -f start.time ]]; then
    log "Could not find start.time file, exiting"
    exit 1
fi

START=$(cat start.time)
ELAPSED=$(($NOW - $START))

log "Operation completed in $(($ELAPSED/3600))h:$(($ELAPSED%3600/60))m:$(($ELAPSED%60))s"
rm -f start.time