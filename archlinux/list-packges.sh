#!/bin/bash

# List all pacman packages in chronological order (oldest first)

pacman -Q --info | grep -E "^(Name|Install Date)" | paste - - | sort -k6