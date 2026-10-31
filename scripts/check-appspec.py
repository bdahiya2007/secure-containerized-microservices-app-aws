#!/usr/bin/env python3
"""Offline checks that keep the deployment files consistent. Used by the PR validate workflow.

- appspec.yaml has the placeholder the deploy workflow replaces, and the container name/port match
  the Terraform task definition and ECS service (a mismatch only shows up as a failed deployment).
- every `uses:` line in the workflows is pinned to a full commit SHA.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
errors = []

appspec = (root / "appspec.yaml").read_text()
if "<TASK_DEFINITION>" not in appspec:
    errors.append("appspec.yaml: the <TASK_DEFINITION> placeholder is missing")
name = re.search(r"ContainerName:\s*(\S+)", appspec)
port = re.search(r"ContainerPort:\s*(\d+)", appspec)
if not name or not port:
    errors.append("appspec.yaml: ContainerName or ContainerPort is missing")
else:
    variables = (root / "terraform/variables.tf").read_text()
    default = re.search(r'variable "project_name".*?default\s*=\s*"([^"]+)"', variables, re.S)
    if not default or default.group(1) != name.group(1):
        errors.append(f"appspec.yaml: ContainerName {name.group(1)} does not match the project_name default in variables.tf")
    ecs = (root / "terraform/codedeploy.tf").read_text()
    if f"container_port   = {port.group(1)}" not in ecs:
        errors.append(f"appspec.yaml: ContainerPort {port.group(1)} does not match codedeploy.tf")

for wf in sorted((root / ".github/workflows").glob("*.yml")):
    for no, line in enumerate(wf.read_text().splitlines(), 1):
        m = re.match(r"\s*-?\s*uses:\s*(\S+)", line)
        if m and not re.search(r"@[0-9a-f]{40}$", m.group(1)):
            errors.append(f"{wf.name}:{no}: {m.group(1)} is not pinned to a full commit SHA")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print("appspec.yaml and the workflows are consistent")
