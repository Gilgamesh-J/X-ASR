# This file is from
# https://github.com/acts-project/acts/blob/main/CI/iwyu/filter.py
import sys
import yaml
import re
import argparse
from collections import namedtuple


Config = namedtuple(
    "Config", ["remove_lines", "replace_lines", "ignore_files"], defaults=[[], [], []]
)


class State:
    skip_file: bool = False


def parse_config(config: Config):
    remove_lines = []
    for s in config["remove_lines"]:
        remove_lines.append(re.compile(s))

    replace_lines = []
    for s in config["replace_lines"]:
        s, r = list(s.items())[0]
        replace_lines.append((re.compile(s), r))

    ignore_files = []
    for s in config["ignore_files"]:
        ignore_files.append(re.compile(s))

    return Config(
        remove_lines=remove_lines,
        replace_lines=replace_lines,
        ignore_files=ignore_files,
    )


def filter(line: str, config: Config, state: State):
    if state.skip_file:
        if line.endswith("---\n"):
            state.skip_file = False
        return None

    if line.endswith(" should add these lines:\n"):
        for s in config.ignore_files:
            if s.search(line):
                state.skip_file = True
                return None

    for s in config.remove_lines:
        if s.search(line):
            return None

    for s, r in config.replace_lines:
        if s.search(line):
            return s.sub(r, line)

    return line


parser = argparse.ArgumentParser()
parser.add_argument("config")
parser.add_argument("input")
parser.add_argument("output")
args = parser.parse_args()

with open(args.config, "r") as config_file:
    try:
        config = yaml.safe_load(config_file)
        config = parse_config(config)
    except yaml.YAMLError as exc:
        print(exc)
        sys.exit(1)

with open(args.input, "r") as input_file, open(args.output, "w") as output_file:
    state = State()

    for line in input_file:
        filtered_line = filter(line, config, state)
        if filtered_line is not None:
            output_file.write(filtered_line)

sys.exit(0)
