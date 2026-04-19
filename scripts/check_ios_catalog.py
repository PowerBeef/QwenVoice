#!/usr/bin/env python3
"""Validate the hosted iPhone model catalog against the shared contract."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path


DEFAULT_CATALOG_URL = "https://downloads.qvoice.app/ios/catalog/v1/models.json"
PROJECT_DIR = Path(__file__).resolve().parents[1]
CONTRACT_PATH = PROJECT_DIR / "Sources/Resources/qwenvoice_contract.json"


def _load_contract() -> dict:
    return json.loads(CONTRACT_PATH.read_text())


def _fetch_catalog(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "VocelloCatalogCheck/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310
        return json.loads(response.read().decode("utf-8"))


def _preferred_ios_descriptor(model: dict) -> dict | None:
    variants = [
        variant
        for variant in model.get("variants", [])
        if "iOS" in variant.get("platforms", []) and variant.get("iosDownloadEligible")
    ]
    if variants:
        preferred = next((variant for variant in variants if variant.get("kind") == "speed"), variants[0])
        return {
            "modelID": model["id"],
            "artifactVersion": preferred["artifactVersion"],
            "estimatedDownloadBytes": preferred.get("estimatedDownloadBytes"),
            "requiredRelativePaths": preferred.get("requiredRelativePaths", []),
        }

    if model.get("iosDownloadEligible"):
        return {
            "modelID": model["id"],
            "artifactVersion": model["artifactVersion"],
            "estimatedDownloadBytes": model.get("estimatedDownloadBytes"),
            "requiredRelativePaths": model.get("requiredRelativePaths", []),
        }

    return None


def _validate_catalog(contract: dict, catalog: dict, catalog_url: str) -> list[str]:
    errors: list[str] = []
    entries = {
        (entry.get("modelID"), entry.get("artifactVersion")): entry
        for entry in catalog.get("models", [])
    }

    checked_models: list[dict] = []
    for model in contract.get("models", []):
        descriptor = _preferred_ios_descriptor(model)
        if descriptor is not None:
            checked_models.append(descriptor)

    for descriptor in checked_models:
        model_id = descriptor["modelID"]
        artifact_version = descriptor["artifactVersion"]
        entry = entries.get((model_id, artifact_version))
        if entry is None:
            errors.append(f"missing entry for {model_id} artifact {artifact_version}")
            continue

        expected_total = descriptor.get("estimatedDownloadBytes")
        actual_total = entry.get("totalBytes")
        if expected_total is not None and actual_total != expected_total:
            errors.append(
                f"{model_id} totalBytes mismatch: expected {expected_total}, found {actual_total}"
            )

        base_url = entry.get("baseURL", "")
        if not isinstance(base_url, str) or not base_url.startswith("https://"):
            errors.append(f"{model_id} baseURL must be https://, found {base_url!r}")

        files = entry.get("files", [])
        file_paths = [item.get("relativePath") for item in files]
        missing_paths = sorted(set(descriptor["requiredRelativePaths"]) - set(file_paths))
        if missing_paths:
            errors.append(f"{model_id} missing required paths: {', '.join(missing_paths)}")

        duplicate_paths = sorted({path for path in file_paths if path and file_paths.count(path) > 1})
        if duplicate_paths:
            errors.append(f"{model_id} duplicate paths: {', '.join(duplicate_paths)}")

        computed_total = 0
        for item in files:
            path = item.get("relativePath", "")
            size_bytes = item.get("sizeBytes")
            sha256 = item.get("sha256", "")
            if not path:
                errors.append(f"{model_id} contains empty relativePath entry")
                continue
            if path.startswith("/") or ".." in path.split("/"):
                errors.append(f"{model_id} invalid relativePath: {path}")
            if not isinstance(size_bytes, int) or size_bytes < 0:
                errors.append(f"{model_id} invalid sizeBytes for {path}: {size_bytes!r}")
            else:
                computed_total += size_bytes
            if not isinstance(sha256, str) or len(sha256) != 64:
                errors.append(f"{model_id} invalid sha256 for {path}")
            file_url = item.get("url")
            if file_url is not None and (not isinstance(file_url, str) or not file_url.startswith("https://")):
                errors.append(f"{model_id} file URL must be https:// for {path}, found {file_url!r}")

        if isinstance(actual_total, int) and actual_total >= 0 and computed_total != actual_total:
            errors.append(
                f"{model_id} file sizes sum to {computed_total}, but totalBytes is {actual_total}"
            )

    if not checked_models:
        errors.append("shared contract exposes no iPhone-downloadable models")

    if not catalog.get("models"):
        errors.append(f"catalog at {catalog_url} returned no models")

    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=DEFAULT_CATALOG_URL, help="Catalog URL to validate.")
    args = parser.parse_args()

    contract = _load_contract()
    checked_models = [
        descriptor["modelID"]
        for model in contract.get("models", [])
        for descriptor in [_preferred_ios_descriptor(model)]
        if descriptor is not None
    ]

    try:
        catalog = _fetch_catalog(args.url)
    except urllib.error.URLError as error:
        print(
            json.dumps(
                {
                    "ok": False,
                    "catalog_url": args.url,
                    "error": f"failed to fetch catalog: {error}",
                },
                indent=2,
            )
        )
        sys.exit(1)

    errors = _validate_catalog(contract, catalog, args.url)
    payload = {
        "ok": not errors,
        "catalog_url": args.url,
        "checked_models": checked_models,
        "error_count": len(errors),
        "errors": errors,
    }
    print(json.dumps(payload, indent=2))
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
