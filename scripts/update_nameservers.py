#!/usr/bin/env python3
"""
Update Route 53 domain nameservers to match a hosted zone.

When Terraform creates a new hosted zone (e.g. via aws_route53_zone), it gets
a fresh delegation set with different nameservers than the ones Route 53
assigned when the domain was originally registered. This script syncs the
domain registration to the hosted zone's nameservers so ACM validation and
DNS resolution work correctly.

Route 53 Domains is a global service only reachable via us-east-1 — the
route53domains client always targets that region regardless of your normal
AWS_REGION setting.

Usage:
    python3 update_nameservers.py                     # auto-detect zone for jenom.com
    python3 update_nameservers.py --zone-id Z0123456  # use a specific zone ID
    python3 update_nameservers.py --dry-run           # preview without applying
"""

import argparse
import sys
import time

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

DOMAIN = "jenom.com"


def get_zone_id_by_name(domain: str) -> str:
    """Find the hosted zone ID for a domain by listing all zones."""
    r53 = boto3.client("route53")
    # Route 53 stores zone names with a trailing dot
    target = domain.rstrip(".") + "."

    paginator = r53.get_paginator("list_hosted_zones")
    matches = []

    for page in paginator.paginate():
        for zone in page["HostedZones"]:
            if zone["Name"] == target:
                matches.append(zone)

    if not matches:
        print(f"ERROR: No hosted zone found for '{domain}'.", file=sys.stderr)
        print("       Check that the zone exists: aws route53 list-hosted-zones", file=sys.stderr)
        sys.exit(1)

    if len(matches) > 1:
        print(f"WARNING: Multiple hosted zones found for '{domain}':")
        for z in matches:
            zone_id = z["Id"].split("/")[-1]
            print(f"  {zone_id}  ({z['Config'].get('Comment', 'no comment')})")
        print("Use --zone-id to specify which one to use.")
        sys.exit(1)

    zone_id = matches[0]["Id"].split("/")[-1]
    return zone_id


def get_zone_nameservers(zone_id: str) -> list:
    """Return the nameservers for a hosted zone's delegation set."""
    r53 = boto3.client("route53")
    resp = r53.get_hosted_zone(Id=zone_id)
    return sorted(resp["DelegationSet"]["NameServers"])


def get_current_domain_nameservers(domain: str) -> list:
    """Return the nameservers currently registered for the domain."""
    domains = boto3.client("route53domains", region_name="us-east-1")
    resp = domains.get_domain_detail(DomainName=domain)
    return sorted(ns["Name"] for ns in resp["Nameservers"])


def update_nameservers(domain: str, nameservers: list, dry_run: bool) -> None:
    """Call route53domains to update the domain's registered nameservers."""
    # route53domains is a global service but only exposed in us-east-1
    domains = boto3.client("route53domains", region_name="us-east-1")

    ns_structs = [{"Name": ns} for ns in nameservers]

    print(f"\nUpdating nameservers for {domain}:")
    for ns in nameservers:
        print(f"  {ns}")

    if dry_run:
        print("\n[DRY RUN] No changes applied.")
        return

    resp = domains.update_domain_nameservers(
        DomainName=domain,
        Nameservers=ns_structs,
    )
    op_id = resp["OperationId"]
    print(f"\nOperation submitted — ID: {op_id}")
    print("Polling for completion...")

    poll_interval = 5
    while True:
        op = domains.get_operation_detail(OperationId=op_id)
        status = op["Status"]
        print(f"  {status}")
        if status in ("SUCCESSFUL", "FAILED", "ERROR"):
            break
        time.sleep(poll_interval)

    if status != "SUCCESSFUL":
        print(f"\nERROR: Operation ended with status '{status}'.", file=sys.stderr)
        sys.exit(1)

    print("\nNameservers updated successfully.")
    print("Global DNS propagation may take a few minutes.")
    print(f"Verify: dig NS {domain} @8.8.8.8")


def main():
    parser = argparse.ArgumentParser(
        description="Sync Route 53 domain registration nameservers to a hosted zone."
    )
    parser.add_argument(
        "--domain",
        default=DOMAIN,
        help=f"Domain name to update (default: {DOMAIN})",
    )
    parser.add_argument(
        "--zone-id",
        help="Hosted zone ID (auto-detected from --domain if omitted)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would change without making any API calls",
    )
    args = parser.parse_args()

    try:
        # Resolve zone ID
        zone_id = args.zone_id or get_zone_id_by_name(args.domain)
        print(f"Hosted zone ID : {zone_id}")

        # Get nameservers from the hosted zone
        zone_ns = get_zone_nameservers(zone_id)
        print(f"Zone nameservers:")
        for ns in zone_ns:
            print(f"  {ns}")

        # Get currently registered nameservers
        current_ns = get_current_domain_nameservers(args.domain)
        print(f"\nCurrent domain nameservers:")
        for ns in current_ns:
            print(f"  {ns}")

        if zone_ns == current_ns:
            print("\nNameservers already match — nothing to do.")
            return

        print("\nMismatch detected — update required.")
        update_nameservers(args.domain, zone_ns, args.dry_run)

    except NoCredentialsError:
        print(
            "ERROR: No AWS credentials found.\n"
            "Configure via environment variables, ~/.aws/credentials, or an IAM role.",
            file=sys.stderr,
        )
        sys.exit(1)
    except ClientError as e:
        print(f"ERROR: AWS API error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
