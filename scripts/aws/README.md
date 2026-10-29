# Kiirunavaara demo — one Splunk Enterprise host on AWS

English runbook for a single combined indexer and search head. A short Swedish summary is at the end.

This is a demo host for the Kiirunavaara presentation. It does not install the demo app, ITSI, or Splunk Show. It does not contain an account id, access key, password, token, or license file.

## Prerequisites

- A Splunk AWS account. The script prints `aws sts get-caller-identity` and does not check a specific account number. Point the CLI at that account yourself.
- AWS CLI v2, non-interactive (`AWS_PAGER` is cleared by the scripts).
- Permission to create the EC2 and IAM objects below, and `ssm:SendCommand` plus `ssm:GetCommandInvocation` if you want the script to confirm Splunk is on the image. Session Manager is used from this same local terminal.
- A Splunk Enterprise 10.6.x x86_64 image this account can already launch in eu-north-1. The script selects the latest match. It does not subscribe to Marketplace and it does not download an RPM.
- The network you will present from, as an IPv4 CIDR. `0.0.0.0/0` is rejected.

The host boots a Splunk Enterprise image that is already launchable in this account, version 10.6.x, the latest match. AWS Marketplace currently lists 10.6.1.1 as the latest Splunk Enterprise AMI. The script resolves the image in eu-north-1 at launch and does not store an AMI id. Record `splunk version` after the first start. This script does not install the demo app.

## Local AWS CLI

Run the scripts from a local terminal with the AWS CLI installed. The region is eu-north-1, which is also the default when `--region` is omitted. A different region is refused. The scripts never prompt.

Point the CLI at the Splunk AWS account with `aws configure` or an existing profile. Pass `--profile` or `AWS_PROFILE`. Do not put keys in the script.

## Parameters

| Flag | Environment | Required | Default |
| --- | --- | --- | --- |
| `--region` | `AWS_REGION` or `AWS_DEFAULT_REGION` | no | `eu-north-1` only |
| `--profile` | `AWS_PROFILE` | no | ambient credentials |
| `--admin-cidr` | `ADMIN_CIDR` | yes | |
| `--ami-id` | `SPLUNK_AMI_ID` | no | latest launchable Splunk Enterprise 10.6.x |
| `--name` | `SPLUNK_DEMO_NAME` | no | `kiruna-splunk-demo` |
| `--vpc-id` | `VPC_ID` | no | script creates a VPC |
| `--subnet-id` | `SUBNET_ID` | with `--vpc-id` | public subnet it creates |
| `--availability-zone` | `AVAILABILITY_ZONE` | no | first available zone |
| `--instance-type` | `INSTANCE_TYPE` | no | `m6i.2xlarge` |
| `--volume-size-gb` | `VOLUME_SIZE_GB` | no | `300` |

`demo-start.sh` and `demo-stop.sh` use `--region`, `--profile`, `--name`, and optional `--instance-id` (`INSTANCE_ID`).

## Why this size

Daily ingest is unmeasured. The plan says not to publish a megabyte claim for the generator, and not to turn the "about half of pre-indexed volume" planning factor into a disk total until a measured day exists. The NFR entitlement below is not that measurement.

- **Instance:** `m6i.2xlarge` (8 vCPU, 32 GiB, x86-64, not burstable). One presenter, one combined indexer and search head, synthetic ticks. Splunk's production single-instance reference is 24 vCPU and 12 GiB, and a single-instance ITSI install publishes a higher CPU floor (32 vCPU in the ITSI hardware table). This box meets the ITSI single-instance RAM floor (32 GiB) so the optional ITSI screen has memory, without buying a production reference machine for an unmeasured demo. Graviton is not used: the Splunk Enterprise 10.6 image used here is x86_64. Override with `--instance-type` if the talk is CPU-bound.
- **Disk:** 300 GiB gp3 on the AMI root volume. Splunk is already installed on that image, so a second disk is not mounted over `/opt/splunk`. gp3 is set to 3000 IOPS and 125 MB/s, encrypted, and kept if the instance is terminated. Splunk's reference hardware says a search head needs at least 300 GB of dedicated storage. 300 GiB is that floor, not `daily ingest × 21 × 0.50`. `frozenTimePeriodInDays = 21` can still freeze early if a size cap is hit; after backfill, check that the oldest event is still inside 14 days. Indexing stops by default when free space on the index volume is under 5 GB.

Sources used for those choices: [Reference hardware](https://help.splunk.com/en/splunk-enterprise/get-started/deployment-capacity-manual/10.4/performance-reference/reference-hardware), [Estimate your storage requirements](https://help.splunk.com/en/splunk-enterprise/get-started/deployment-capacity-manual/10.4/hardware-capacity-planning/estimate-your-storage-requirements), [Install on Linux](https://help.splunk.com/en/splunk-enterprise/get-started/install-and-upgrade/10.4/install-splunk-enterprise-on-linux-or-macos/install-on-linux), [Architecture and ports](https://help.splunk.com/en/splunk-enterprise/get-started/install-and-upgrade/10.4/plan-your-splunk-enterprise-installation/splunk-enterprise-architecture-and-processes), [How licensing works](https://help.splunk.com/en/splunk-enterprise/administer/admin-manual/10.4/configure-splunk-licenses/how-splunk-enterprise-licensing-works), [Plan your ITSI deployment](https://help.splunk.com/en/splunk-it-service-intelligence/splunk-it-service-intelligence/install-and-upgrade/4.21/planning/plan-your-itsi-deployment). Amazon Linux 2023 x86-64 is a supported Enterprise platform in the installation manual's system requirements.

## Local shortcut

The agent-store folder is deep under `~/Library`. On your Mac, run `docs/aws/link-local.sh` from this folder (paste that file into Terminal the first time). It finds the store and links `~/dev/SplunkMiningDemoApp` to it. `~/dev` is a directory in your home folder, not a user named `dev`.

After it runs, the scripts are at `~/dev/SplunkMiningDemoApp/docs/aws/`. Run the script again if Cursor moves the store. It only creates the symlink. It does not read AWS keys or a Splunk password.

## Commands

From a local terminal, with the CLI already aimed at eu-north-1:

```bash
export ADMIN_CIDR=203.0.113.10/32
# export AWS_PROFILE=your-splunk-profile
# export APP_BUCKET=kiruna-splunk-demo-app

bash scripts/aws/setup-splunk-enterprise.sh
bash scripts/aws/demo-start.sh
bash scripts/aws/demo-stop.sh
bash scripts/aws/create-app-bucket.sh
```

`create-app-bucket.sh` stores the bucket name `kiruna-splunk-demo-app`. `APP_BUCKET` or `--app-bucket` overrides it. The same name is the default for `demo-pipeline.sh` and `install-demo-app.sh`. The bucket is private, in eu-north-1, and new objects use AES-256. The underlying call is:

```bash
aws s3api create-bucket \
  --bucket kiruna-splunk-demo-app \
  --region eu-north-1 \
  --create-bucket-configuration LocationConstraint=eu-north-1
```

The same flags work if you prefer them to environment variables. `203.0.113.10/32` is documentation-only; use the CIDR you will actually connect from.

If `ec2:CreateVpc` is denied by an organization service control policy, pass a public subnet that already exists. Administrator access does not override that deny. The subnet must already route `0.0.0.0/0` to an internet gateway. The script then creates the security group and the instance in that network, and it does not create a VPC, subnet, or internet gateway.

```bash
bash scripts/aws/setup-splunk-enterprise.sh \
  --admin-cidr 203.0.113.10/32 \
  --vpc-id vpc-xxxxxxxx \
  --subnet-id subnet-xxxxxxxx
```

## Desktop Cursor and the AWS Deployments plugin

The AWS Deployments plugin can sit in desktop Cursor. It does not replace these scripts, and it does not open this Cloud agent. A project rule, `.cursor/rules/kiruna-aws-demo.mdc`, tells that desktop agent to ignore the plugin's "generate infrastructure" path (no CDK, CloudFormation, Terraform, Elastic Beanstalk, ECS, or App Runner) and to run this sequence in the local terminal where the AWS CLI is already configured.

```bash
bash scripts/aws/demo-pipeline.sh --admin-cidr 203.0.113.10/32
# change the Marketplace admin password, then Emil installs the NFR
bash scripts/aws/create-app-bucket.sh
bash scripts/aws/demo-pipeline.sh --after-manual-gate
```

The first command creates the host, or starts it if it already exists, and then stops. `create-app-bucket.sh` creates `kiruna-splunk-demo-app` unless `APP_BUCKET` is set. The last command packages `lkab_kiruna_demo` (from this checkout, or from the already-fetched branch `cursor/kiruna-app-v0.1`), uploads that tarball to that bucket, installs it with Systems Manager, deletes the object, and runs `validate-demo.sh`.

The 15-minute download URL is sent only inside the Systems Manager command and is not printed. It is for the app tarball only. Do not use this path for a license file or a password.

`validate-demo.sh` checks the package layout and, on the instance, `splunk version`, the app directory, and the `kiruna_events` stanza. It does not log in. Saving setup, enabling the generator, and reading Shift Brief stay in Splunk Web. AppInspect runs only when `splunk-appinspect` is on PATH. Zero failures is still the packaging exit for that CLI.

`install-demo-app.sh` and `validate-demo.sh` can be run on their own with the same `--profile`, `--region`, `--name`, and `--instance-id` flags. `--local-only` on validate skips the instance.

Re-running setup does not replace an instance that is already there. It will add the current admin CIDR to the security group and leave older CIDRs in place. Changing instance type or volume size means tearing down and running setup again.

## What is created

- A VPC `10.42.0.0/16`, public subnet `10.42.1.0/24`, internet gateway, and a default route, **or** the VPC and public subnet you passed. A supplied subnet must already route `0.0.0.0/0` to an internet gateway. The script does not change your routes.
- A security group: TCP **8000** (Splunk Web) and TCP **8089** (splunkd) from `ADMIN_CIDR` only. No SSH. Port 22 is closed because the plan does not need it. HEC 8088 and forwarder 9997 stay closed; v1 ingest is the local modular input. Egress is TCP 443 and DNS (TCP/UDP 53) only, so the instance can reach Systems Manager. `0.0.0.0/0` is not used as an ingress rule.
- An instance role with `AmazonSSMManagedInstanceCore`. No static keys on the instance. IMDSv2 is required.
- One `m6i.2xlarge` instance, unless you override the type. OS timezone is set to `Europe/Stockholm`.
- The latest Splunk Enterprise 10.6.x x86_64 image this account can already launch. The script does not subscribe to Marketplace.
- One encrypted 300 GiB gp3 volume, the AMI root, tagged `kiruna-volume=splunk-data` and kept if the instance is stopped or terminated. No Elastic IP and no NAT gateway, so a stop releases the public address and does not leave a NAT charge. The volume still bills while stopped.
- Splunk is already on the image and starts with the instance. This script does not set the admin password.

## After the instance is up

The script prints these steps with the instance id filled in. They are manual. The script's success does not wait on them.

1. From the same local CLI, with the Session Manager plugin: `aws ssm start-session --target INSTANCE_ID --region eu-north-1`. Splunk is already installed and started by the image. Sign in with the initial admin login published in the AWS Marketplace usage instructions for the Splunk Enterprise AMI, then change that password. Do not put the password in the repo, the script, or user-data. Record `sudo /opt/splunk/bin/splunk version`.
2. Emil installs the NFR license himself. It is unrestricted, **50 GB/day**. In Splunk Web: Settings → Licensing → Add license. Or, after he copies the file onto the instance himself: `sudo /opt/splunk/bin/splunk add licenses /path/to/nfr.lic`. That path is a placeholder. There is no `.lic` file in this repo. A missing license, a trial countdown, or an unmeasured daily volume is not a failure of this setup.

The 50 GB/day figure is the NFR entitlement, not a measured ingest total. Do not publish an unmeasured megabyte claim for the generator.

`demo-start.sh` only starts this instance. If it is already running, it says so and exits 0. `demo-stop.sh` only stops it. If it is already stopped, it says so and exits 0. Neither command terminates the instance or deletes the volume, the security group, or the Splunk install.

## Tear down

This is not what `demo-stop.sh` does. Stop pauses compute. Tear down deletes the demo.

Set `NAME` and `AWS_REGION` to the values you used. Add `--profile` on a laptop. Terminate the instance and wait until it is terminated. Delete the data volume tagged `kiruna-volume=splunk-data` (`DeleteOnTermination` is false, so terminate leaves it). Delete the security group named `$NAME`.

If the script created the network (`owned_network: yes` in the setup output, tag `kiruna-owned=script`), delete the subnet, detach and delete the internet gateway, then delete the VPC. If you passed your own VPC, leave it.

Then remove the instance profile and role `$NAME-profile` and `$NAME-role`: remove the role from the profile, delete the profile, delete the inline policy `splunk-installer-read` if it exists, detach `AmazonSSMManagedInstanceCore`, and delete the role. The managed-policy ARN uses partition `aws` (or the partition in your caller ARN), not your account id: `arn:PARTITION:iam::aws:policy/AmazonSSMManagedInstanceCore`.

## Swapping this host to Splunk Show later

The VPC, subnet, internet route, and the security group rules for 8000 and 8089 are independent of where the Splunk bits come from. In `setup-splunk-enterprise.sh`, the only Enterprise-specific launch path is the block marked `BEGIN INSTANCE_SOURCE` / `END INSTANCE_SOURCE`: the 10.6.x image lookup and the `RunInstances` call. A later Splunk Show image replaces that block and keeps the network and security group as they are. Do not add a license file, a password, or an AMI id in that block either.

## På svenska

Skripten skapar, startar och stoppar **en** Splunk Enterprise-värd för Kiirunavaara-demon. Kör dem från en lokal terminal med AWS CLI. Regionen är eu-north-1. Skripten ställer inga frågor.

Du anger vilket CIDR som får nå port 8000 och 8089. Instansen startar från en Splunk Enterprise-avbildning 10.6.x som kontot redan kan starta, den senaste träffen. Ingen licensfil, inget lösenord, ingen AMI-id och ingen token ligger i repot.

När instansen är uppe gör en person två saker. Först byter du det initiala admin-lösenordet från Marketplace-avbildningen. Sedan lägger Emil själv in NFR-licensen i Splunk Web: obegränsad, 50 GB per dag. Skriptet väntar inte på licensen och avslutas inte med fel om den saknas.

`demo-pipeline.sh` är ordningen för Cursor på skrivbordet. Första körningen skapar eller startar värden och stannar där. Efter lösenord och NFR installerar `--after-manual-gate` appen `lkab_kiruna_demo` och kör kontrollerna. AWS-pluginet ska inte skriva en ny CDK- eller CloudFormation-stack för den här demon.

`demo-stop.sh` stoppar bara instansen. Disk, säkerhetsgrupp och installationen ligger kvar. `demo-start.sh` startar samma instans. Publik IP kan bytas efter stopp.

Standard: `m6i.2xlarge` och 300 GiB gp3 för `/opt/splunk`. Motiveringen står på engelska ovan.
