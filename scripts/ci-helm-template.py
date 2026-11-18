#!/usr/bin/env python3
"""Render every Helm chart referenced by an ArgoCD Application.

Repo, chart, version, release name, namespace and values files are derived
from argocd/applications/**/*.yaml so CI always checks what ArgoCD deploys.
Only values files stored in this repo ($values/...) are used; Applications
with inline values only are skipped. Requires PyYAML (installed with yamllint)
and helm.
"""
import pathlib
import os
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
KUBE_VERSION = "1.36.0"


def apps():
    for path in sorted((ROOT / "argocd" / "applications").rglob("*.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            if not isinstance(doc, dict) or doc.get("kind") != "Application":
                continue
            spec = doc.get("spec", {})
            sources = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
            for src in sources:
                if "chart" in src:
                    yield path, doc, src


def main():
    # Isolated helm state so a developer's local repo list cannot interfere.
    tmp = tempfile.mkdtemp(prefix="helm-ci-")
    os.environ["HELM_REPOSITORY_CONFIG"] = os.path.join(tmp, "repositories.yaml")
    os.environ["HELM_REPOSITORY_CACHE"] = os.path.join(tmp, "cache")
    os.environ["HELM_CACHE_HOME"] = os.path.join(tmp, "home-cache")
    failures = 0
    count = 0
    for path, doc, src in apps():
        rel = path.relative_to(ROOT)
        helm = src.get("helm", {})
        values = [
            ROOT / v.replace("$values/", "", 1)
            for v in helm.get("valueFiles", [])
            if v.startswith("$values/")
        ]
        if not values:
            print(f"SKIP {rel}: no repo values files ({src['chart']})")
            continue
        missing = [str(v) for v in values if not v.is_file()]
        if missing:
            print(f"FAIL {rel}: values file not found: {missing}")
            failures += 1
            continue
        release = helm.get("releaseName") or doc["metadata"]["name"]
        cmd = [
            "helm", "template", release, src["chart"],
            "--repo", src["repoURL"],
            "--version", str(src["targetRevision"]),
            "--namespace", doc["spec"]["destination"]["namespace"],
            "--kube-version", KUBE_VERSION,
        ]
        for v in values:
            cmd += ["-f", str(v)]
        count += 1
        res = subprocess.run(cmd, capture_output=True, text=True)
        label = f"{src['chart']} {src['targetRevision']} ({rel})"
        if res.returncode == 0:
            print(f"OK   {label}")
        else:
            failures += 1
            print(f"FAIL {label}\n{res.stderr}")
    print(f"helm template: {count - failures}/{count} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
