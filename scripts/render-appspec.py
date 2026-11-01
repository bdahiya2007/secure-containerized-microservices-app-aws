#!/usr/bin/env python3
"""Renders appspec.yaml for a CodeDeploy blue/green deployment.

Usage: render-appspec.py TASK_DEFINITION_ARN [CAPACITY_PROVIDER_STRATEGY_JSON]

- Replaces the <TASK_DEFINITION> placeholder with the task definition revision to deploy.
- If the ECS service runs on a capacity provider strategy (enable_fargate_spot), copies that strategy into the
  appspec, so the tasks CodeDeploy starts follow the same Fargate / Fargate Spot mix as the service. The strategy
  is the JSON the ECS API returns: [{"capacityProvider": "FARGATE", "weight": 1, "base": 1}, ...]. Empty, null or
  missing means the service uses a launch type, and the appspec stays as it is.
Writes the result to stdout. Standard library only.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAME = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def render(task_definition, strategy_json=""):
    text = (ROOT / "appspec.yaml").read_text()
    if "<TASK_DEFINITION>" not in text:
        raise ValueError("appspec.yaml has no <TASK_DEFINITION> placeholder")
    if not re.fullmatch(r"arn:aws:ecs:[a-z0-9-]+:\d{12}:task-definition/[A-Za-z0-9_-]+:\d+", task_definition):
        raise ValueError("the task definition must be an ECS task definition revision ARN")
    text = text.replace("<TASK_DEFINITION>", task_definition)

    strategy = json.loads(strategy_json) if strategy_json.strip() else None
    if strategy:
        lines = ["        CapacityProviderStrategy:"]
        for item in strategy:
            provider, weight, base = item["capacityProvider"], int(item.get("weight", 0)), int(item.get("base", 0))
            if not NAME.match(provider) or weight < 0 or base < 0:
                raise ValueError(f"invalid capacity provider strategy item: {item}")
            lines += [f"          - CapacityProvider: {provider}", f"            Base: {base}", f"            Weight: {weight}"]
        text = text.rstrip("\n") + "\n" + "\n".join(lines) + "\n"
    return text


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    try:
        sys.stdout.write(render(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else ""))
    except (ValueError, KeyError, json.JSONDecodeError) as err:
        sys.exit(f"render-appspec: {err}")
