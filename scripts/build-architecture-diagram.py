#!/usr/bin/env python3
"""Builds the complete architecture diagram (both Regions, disaster recovery, delivery) as one SVG with the official AWS Architecture Icons.

Usage:  scripts/build-architecture-diagram.py --icons <folder with the extracted AWS icon package> --out docs/images/architecture-complete.svg

The icons are not stored in this repository. Download the "Icon package" from https://aws.amazon.com/architecture/icons/ (this diagram was
made with the 07/31/2026 release) and extract it. AWS allows its architecture icons to be used to create architecture diagrams; they are
embedded here unmodified and resized only, and the diagram credits them. The generator only reads the icon files; it runs nothing from them.
Standard library only. Render the SVG to a PNG with any browser or SVG tool.
"""
import argparse
import base64
import glob
import html
import os
import sys

p = argparse.ArgumentParser()
p.add_argument("--icons", required=True, help="folder with the extracted AWS icon package")
p.add_argument("--out", required=True)
args = p.parse_args()

W, H = 2700, 1840
ICON_CACHE = {}


def find(pattern):
    hits = sorted(h for h in glob.glob(os.path.join(args.icons, "**", pattern), recursive=True) if "__MACOSX" not in h and "/._" not in h)
    if not hits:
        sys.exit(f"icon not found: {pattern}")
    return hits[0]


def data_uri(path):
    if path not in ICON_CACHE:
        ICON_CACHE[path] = base64.b64encode(open(path, "rb").read()).decode()
    return "data:image/svg+xml;base64," + ICON_CACHE[path]


out = []
add = out.append
esc = html.escape


def text(x, y, s, size=15, weight="normal", fill="#232F3E", anchor="middle", halo=True):
    style = f'font-family="Arial, Helvetica, sans-serif" font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}"'
    if halo:
        style += ' stroke="#ffffff" stroke-width="4" paint-order="stroke" stroke-linejoin="round"'
    add(f'<text x="{x}" y="{y}" {style}>{esc(s)}</text>')


def lines(x, y, ls, size=15, weight="normal", fill="#232F3E", anchor="middle", gap=None, halo=True):
    gap = gap or size + 4
    for i, s in enumerate(ls):
        text(x, y + i * gap, s, size, "bold" if (i == 0 and weight == "bold") else "normal", fill, anchor, halo)


def icon(pattern, x, y, size, label=None, sub=(), label_w=None):
    path = find(pattern)
    add(f'<image x="{x}" y="{y}" width="{size}" height="{size}" href="{data_uri(path)}" xlink:href="{data_uri(path)}"/>')
    if label:
        cx = x + size / 2
        text(cx, y + size + 20, label, 15, "bold")
        for i, s in enumerate(sub):
            text(cx, y + size + 38 + i * 17, s, 13, "normal", "#37475A")
    return (x + size / 2, y + size / 2)


def frame(x, y, w, h, color, title, icon_pattern=None, dash=None, fill="none", title_size=17, title_dx=44):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="3" fill="{fill}" stroke="{color}" stroke-width="2"{d}/>')
    if icon_pattern:
        path = find(icon_pattern)
        add(f'<image x="{x}" y="{y}" width="34" height="34" href="{data_uri(path)}" xlink:href="{data_uri(path)}"/>')
    text(x + title_dx, y + 23, title, title_size, "bold", "#232F3E", "start", halo=False)


MARKERS = {}


def marker(color):
    if color not in MARKERS:
        MARKERS[color] = f"m{len(MARKERS)}"
    return MARKERS[color]


def arrow(points, color="#232F3E", dash=None, width=2.5, label=None, lpos=None, lanchor="middle", lsize=13, both=False):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    pts = " ".join(f"{px},{py}" for px, py in points)
    m = marker(color)
    start = f' marker-start="url(#{m}s)"' if both else ""
    add(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="{width}"{d} marker-end="url(#{m})"{start}/>')
    if label:
        lx, ly = lpos if lpos else points[len(points) // 2]
        for i, s in enumerate(label if isinstance(label, (list, tuple)) else [label]):
            text(lx, ly + i * (lsize + 3), s, lsize, "normal", color, lanchor)


def box(x, y, w, h, title, sub=(), fill="#F2F3F3", stroke="#5A6C86"):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="2"/>')
    text(x + w / 2, y + 28, title, 16, "bold", halo=False)
    for i, s in enumerate(sub):
        text(x + w / 2, y + 50 + i * 17, s, 13, "normal", "#37475A", halo=False)


# ---- palette (AWS Architecture Icons guidelines for the group frames) ----
TEAL, PURPLE, GREEN, ORANGE, BLUE, RED, GREY = "#00A4A6", "#8C4FFF", "#7AA116", "#ED7100", "#147EBA", "#DD344C", "#5A6C86"
DR = "#C7511F"   # the disaster-recovery paths

# ---- icon patterns ----
SV = lambda n: f"Arch_{n}_64.svg"
RS = lambda n: f"Res_{n}_48.svg"

# =============================================================================================================================
# canvas
add(f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
DEFS_AT = len(out)
add('<rect width="100%" height="100%" fill="#ffffff"/>')
text(40, 50, "Product Service on AWS: containerized microservices with Aurora Global Database disaster recovery", 30, "bold", anchor="start", halo=False)
text(40, 80, "Region A (us-east-1) serves users; Region B (us-west-2) is a pilot light: one task and a read-only database, ready to take over. Written for a demo: one NAT gateway, single-instance clusters.", 16, "normal", "#37475A", "start", halo=False)

# ---- top: users, DNS, health check, delivery ----
u = icon("Res_User_48_Light.svg", 276, 118, 56, "Users and clients", ["HTTPS 443, TLS 1.3", "one address by default"])
r53 = icon(SV("Amazon-Route-53"), 272, 262, 64, "Route 53", ["failover routing"])
arrow([(304, 192 + 24), (304, 262)], BLUE, label="DNS lookup", lpos=(318, 250), lanchor="start")
alarm = icon(RS("Amazon-CloudWatch_Alarm"), 560, 270, 48, "CloudWatch alarm", ["ECS RunningTaskCount below 1", "for 3 of 3 minutes"])
arrow([(560, 294), (342, 294)], DR, dash="8 5", label=["health check follows the", "alarm's metric data"], lpos=(452, 262))

gh = box(1380, 118, 270, 78, "GitHub Actions", ["OIDC role, no stored keys", "tests, scans, build, deploy"], "#F7F7F7", GREY)
box(1700, 118, 960, 78, "Terraform switches (off by default in the code)", ["enable_https  |  enable_aurora  |  enable_dr_replica  |  enable_dr_failover", "With all four on, this is the design that was applied and drilled on 2026-11-07"], "#F7F7F7", GREY)

# =============================================================================================================================
# REGION A
RA_X, RA_Y, RA_W, RA_H = 40, 410, 1600, 1010
frame(RA_X, RA_Y, RA_W, RA_H, TEAL, "Region A: us-east-1 (active)", "Region_32.svg", dash="9 6")

# regional services strip (row 0)
Y0 = 478
ecr_a = icon(SV("Amazon-Elastic-Container-Registry"), 1470, Y0, 64, "ECR", ["image, scan on push"])
sec_a = icon(SV("AWS-Secrets-Manager"), 1290, Y0, 64, "Secrets Manager", ["self-managed secret,", "rotated every 7 days"])
lam_a = icon(SV("AWS-Lambda"), 1130, Y0, 64, "Lambda", ["rotation function,", "no VPC"])
acm_a = icon(SV("AWS-Certificate-Manager"), 710, Y0, 64, "ACM", ["certificate for", "the main name"])
s3_a = icon(SV("Amazon-Simple-Storage-Service"), 560, Y0, 64, "S3", ["access logs", "(private, expiring)"])
cw_a = icon(SV("Amazon-CloudWatch"), 410, Y0, 64, "CloudWatch", ["logs, dashboard,", "Container Insights"])
asc_a = icon(SV("AWS-Application-Auto-Scaling"), 260, Y0, 64, "Auto Scaling", ["2 to 4 tasks:", "CPU 60 %, 500 req/task"])
cd_a = icon(SV("AWS-CodeDeploy"), 110, Y0, 64, "CodeDeploy", ["blue/green, 10 % a", "minute, auto rollback"])
arrow([(1250 - 52, Y0 + 32), (1290 - 6, Y0 + 32)], PURPLE, label="rotates", lpos=(1244, Y0 - 8))

# the VPC
VA_X, VA_Y, VA_W, VA_H = 70, 640, 1160, 730
frame(VA_X, VA_Y, VA_W, VA_H, PURPLE, "VPC 10.0.0.0/16, two Availability Zones", "Virtual-private-cloud-VPC_32.svg")
igw_a = icon(RS("Amazon-VPC_Internet-Gateway"), 1000, 612, 48, "Internet gateway", [])

frame(100, 690, 1100, 200, GREEN, "Public subnets", "Public-subnet_32.svg")
alb_a = icon(RS("Elastic-Load-Balancing_Application-Load-Balancer"), 860, 735, 48, "Application Load Balancer", ["HTTPS 443 + ACM, port 80 redirects", "access logs on"])
nat_a = icon(RS("Amazon-VPC_NAT-Gateway"), 420, 735, 48, "NAT gateway", ["outbound 443 only"])
arrow([(1024, 660), (1024, 700), (908, 700), (908, 745)], GREY, width=2)

frame(100, 930, 1100, 405, TEAL, "Private subnets (no public IPs)", "Private-subnet_32.svg")
frame(130, 975, 640, 215, ORANGE, "ECS service on Fargate", "Auto-Scaling-group_32.svg", dash="8 5")
ecs_a = icon(SV("Amazon-Elastic-Container-Service"), 160, 1020, 64, "ECS", ["cluster"])
fg_a = icon(SV("AWS-Fargate"), 280, 1020, 64, "Fargate", ["0.25 vCPU, 512 MB"])
for i, tx in enumerate((410, 470, 530)):
    icon(RS("Amazon-Elastic-Container-Service_Task"), tx, 1030, 48)
lines(500, 1105, ["2 on-demand + Fargate Spot", "above 2, spread over 2 zones"], 13, fill="#37475A")
db_a = icon(SV("Amazon-Aurora"), 1000, 1020, 64, "Aurora PostgreSQL", ["Serverless v2, 0.5 to 4 ACU", "PRIMARY (writer), v18.6", "encrypted, 7-day backups"])
s3e = icon(RS("Amazon-VPC_Endpoints"), 140, 1250, 48, "S3 gateway endpoint", [])
lines(650, 1290, ["Security groups: internet to ALB (443, 80) to tasks (3000) to database (5432)", "Tasks read the secret at runtime with a task role that can read only that secret"], 13, fill="#37475A")
arrow([(884, 848), (884, 962), (770, 962), (770, 1050)], GREY, width=2.5, label="HTTP 3000, TLS ends at the ALB", lpos=(900, 918), lanchor="start")
arrow([(610, 1062), (1000, 1052)], GREY, width=2.5, label="PostgreSQL 5432, TLS", lpos=(805, 1040))
arrow([(1162, 574), (1162, 985), (1032, 985), (1032, 1020)], PURPLE, dash="6 5", label=["ModifyDBCluster", "(no login)"], lpos=(1172, 800), lanchor="start", lsize=12)

ops = ["Security and operations",
       "TLS 1.3 at the load balancer; ACM certificate per Region",
       "Tasks: private, non-root, read-only filesystem, no secret in",
       "  the environment; the task role can read only one secret",
       "IAM roles trust only ECS in this account (confused deputy)",
       "DB password rotated every 7 days, replicated to Region B",
       "CI per pull request: secret scan, Semgrep, CodeQL, Trivy,",
       "  Checkov, npm audit; the image is scanned again weekly",
       "Releases: blue/green with automatic rollback (CodeDeploy)",
       "Logs: ALB access logs to a private S3 bucket, CloudWatch"]
add('<rect x="1256" y="650" width="372" height="300" rx="8" fill="#F7F7F7" stroke="#5A6C86" stroke-width="2"/>')
text(1442, 678, ops[0], 16, "bold", halo=False)
for i, line in enumerate(ops[1:]):
    text(1268, 710 + i * 26, line, 12, "normal", "#37475A", "start", halo=False)

# =============================================================================================================================
# REGION B
RB_X, RB_Y, RB_W, RB_H = 1700, 410, 960, 1010
frame(RB_X, RB_Y, RB_W, RB_H, TEAL, "Region B: us-west-2 (pilot light)", "Region_32.svg", dash="9 6")
ecr_b = icon(SV("Amazon-Elastic-Container-Registry"), 1760, Y0, 64, "ECR", ["replica, same image"])
sec_b = icon(SV("AWS-Secrets-Manager"), 1930, Y0, 64, "Secrets Manager", ["replica, new versions", "follow automatically"])
kms_b = icon(SV("AWS-Key-Management-Service"), 2110, Y0, 64, "KMS", ["key for the", "secondary's storage"])
acm_b = icon(SV("AWS-Certificate-Manager"), 2270, Y0, 64, "ACM", ["own certificate:", "Region B name + main name"])
cw_b = icon(SV("Amazon-CloudWatch"), 2450, Y0, 64, "CloudWatch", ["logs, Container Insights"])

VB_X, VB_Y, VB_W, VB_H = 1730, 640, 900, 730
frame(VB_X, VB_Y, VB_W, VB_H, PURPLE, "VPC 10.1.0.0/16, two Availability Zones", "Virtual-private-cloud-VPC_32.svg")
igw_b = icon(RS("Amazon-VPC_Internet-Gateway"), 2300, 612, 48, "Internet gateway", [])
frame(1760, 690, 840, 200, GREEN, "Public subnets", "Public-subnet_32.svg")
alb_b = icon(RS("Elastic-Load-Balancing_Application-Load-Balancer"), 2160, 735, 48, "Application Load Balancer", ["HTTPS 443 + own ACM certificate", "port 80 redirects"])
nat_b = icon(RS("Amazon-VPC_NAT-Gateway"), 1840, 735, 48, "NAT gateway", [])
arrow([(2324, 660), (2324, 700), (2208, 700), (2208, 745)], GREY, width=2)
frame(1760, 930, 840, 405, TEAL, "Private subnets (no public IPs)", "Private-subnet_32.svg")
db_b = icon(SV("Amazon-Aurora"), 1840, 1020, 64, "Aurora PostgreSQL", ["Serverless v2, 0.5 to 4 ACU", "SECONDARY: read-only copy", "own KMS key, reader endpoint"])
frame(2130, 975, 440, 215, ORANGE, "ECS on Fargate", "Auto-Scaling-group_32.svg", dash="8 5")
fg_b = icon(SV("AWS-Fargate"), 2160, 1020, 64, "Fargate", ["one task, kept running"])
icon(RS("Amazon-Elastic-Container-Service_Task"), 2290, 1030, 48)
lines(2410, 1112, ["scaled to 2 by hand", "in a failover"], 13, fill="#37475A")
arrow([(2208, 848), (2208, 962), (2314, 962), (2314, 1028)], GREY, width=2.5)
arrow([(2160, 1062), (1908, 1062)], GREY, width=2.5, label="reads, 5432", lpos=(2034, 1046), lsize=12)
lines(2180, 1290, ["Same posture as Region A: private tasks behind a NAT gateway; the", "task role can read only the replica of the database secret"], 13, fill="#37475A")

# =============================================================================================================================
# routing (top bus) and cross-Region paths
arrow([(272, 280), (236, 280), (236, 386), (884, 386), (884, 735)], BLUE, width=3, label="PRIMARY", lpos=(800, 378))
arrow([(272, 306), (214, 306), (214, 400), (2184, 400), (2184, 735)], DR, width=3, dash="10 6", label="SECONDARY (when the primary is unhealthy)", lpos=(1500, 394))
arrow([(1515, 196), (1515, Y0)], GREY, width=2.5, label=["build, push", "(commit SHA tag)"], lpos=(1585, 226), lanchor="start")
arrow([(1420, 118), (1420, 108), (142, 108), (142, Y0)], GREY, width=2.5, label="start a deployment", lpos=(760, 101))

# disaster-recovery replication
arrow([(1064, 1052), (1838, 1052)], DR, width=4, both=False, label=["Aurora Global Database", "storage-level replication"], lpos=(1410, 1010), lsize=14)
lines(1410, 1086, ["measured: 0 rows lost at about 520 writes/s;", "lag at most 0.7 s; writer ready in 31 to 38 s"], 12, fill=DR)
arrow([(1534, Y0 + 20), (1760 + 0, Y0 + 20)], DR, width=3, dash="10 6", label="image replication", lpos=(1647, Y0 + 8), lsize=12)
arrow([(1354, Y0 - 12), (1354, 452), (1900, 452), (1900, Y0 + 20), (1930, Y0 + 20)], DR, width=3, dash="10 6", label="secret replication", lpos=(1640, 446), lsize=12)

# =============================================================================================================================
# legend and measured results
LY = 1450
box(40, LY, 1050, 350, "What the drills measured (2026-11-07, Region A to Region B)", [], "#FFF8F0", DR)
rows = [
    ("Database failover, data loss allowed:", "writer ready in Region B 31 to 38 s after the command; 0 rows lost (20,764 acknowledged, 20,764 present)"),
    ("Main name moved to Region B:", "42 to 56 s when Region A's tasks are gone; about 3 min when they run but fail health checks"),
    ("Planned switchover to Region B and back:", "56 s and 53 s; about 32 s of failed reads on the main name (open item)"),
    ("Password rotation, end to end:", "104 s with no failed request; the first run found and fixed a retry livelock"),
    ("Fail-back after a failover:", "refused for 13 min 20 s while AWS resynced the old primary; then 59 s"),
    ("Details, evidence and every issue found:", "docs/DR_Test_Results.md  |  plan and design: docs/DR_Runbook.md, docs/DR_Design_Decisions.md"),
]
for i, (a, b) in enumerate(rows):
    text(60, LY + 62 + i * 44, a, 14, "bold", "#232F3E", "start", halo=False)
    text(60, LY + 62 + i * 44 + 18, b, 13, "normal", "#37475A", "start", halo=False)

box(1120, LY, 760, 350, "How to read it", [], "#F7F7F7", GREY)
leg = [
    ((1150, LY + 62), [(1150, LY + 62), (1260, LY + 62)], GREY, None, "request and data path inside a Region"),
    ((1150, LY + 100), [(1150, LY + 100), (1260, LY + 100)], BLUE, None, "DNS: primary record"),
    ((1150, LY + 138), [(1150, LY + 138), (1260, LY + 138)], DR, "10 6", "disaster recovery: failover record and replication"),
    ((1150, LY + 176), [(1150, LY + 176), (1260, LY + 176)], PURPLE, "6 5", "secret rotation (control plane, no database login)"),
]
for _, pts, col, dash, label in leg:
    arrow(pts, col, dash=dash, width=3)
    text(1280, pts[0][1] + 5, label, 14, "normal", "#232F3E", "start", halo=False)
lines(1150, LY + 222, ["Region A serves all traffic. Route 53 sends the main name to Region B only when Region A's", "targets or its alarm-fed health check turn unhealthy. Both load balancers admit only the", "owner's address by default; the API has no authentication, so that restriction is the guard."], 13, fill="#37475A", anchor="start", halo=False)
lines(1150, LY + 300, ["Icons: AWS Architecture Icons (07/31/2026 release), used unmodified and resized only."], 13, fill="#37475A", anchor="start", halo=False)

# arrowhead markers
defs = ["<defs>"]
for color, mid in MARKERS.items():
    defs.append(f'<marker id="{mid}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>')
    defs.append(f'<marker id="{mid}s" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>')
defs.append("</defs>")
out.insert(DEFS_AT, "\n".join(defs))
add("</svg>")

open(args.out, "w").write("\n".join(out))
print(f"wrote {args.out}: {W}x{H}, {len(out)} elements, {os.path.getsize(args.out) // 1024} KB")
