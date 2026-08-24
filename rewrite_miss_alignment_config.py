#!/usr/bin/env python3
"""Write a runtime config whose training directory is local Condor scratch."""

from pathlib import Path
import argparse

import yaml


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_config", type=Path)
    parser.add_argument("output_config", type=Path)
    parser.add_argument("training_directory", type=Path)
    args = parser.parse_args()

    with args.input_config.open("r", encoding="utf-8") as stream:
        config = yaml.safe_load(stream)

    if not isinstance(config, dict) or not isinstance(config.get("general"), dict):
        raise ValueError("Config is missing the required 'general' mapping")

    config["general"]["training_directory"] = str(
        args.training_directory.resolve()
    )
    with args.output_config.open("w", encoding="utf-8") as stream:
        yaml.safe_dump(config, stream, sort_keys=False)


if __name__ == "__main__":
    main()
