"""Secrets Manager rotation function for the Aurora master password (single-user rotation).

Why this exists: Secrets Manager's managed credentials (manage_master_user_password) are not supported with Aurora
Global Database, so the secret is self-managed and this function rotates it. See docs/DR_Design_Decisions.md.

How it differs from AWS's sample rotation functions: the new password is set through the RDS control plane
(ModifyDBCluster), not by logging in to the database. So the function needs no VPC, no database driver and no network
path to the cluster. The trade-off is that testSecret cannot try a login with the pending password (the Data API, the
only login-free way to run SQL, always uses the secret's current version). It checks that the cluster is available and
that the password change has been applied instead; the application re-reads the secret and retries once after a failed
login, and the failover drill exercises a rotation end to end.

The four steps follow the Secrets Manager contract (docs: "Rotation by Lambda function"). Each step is safe to run again.
"""
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# RDS rejects / ' " @ and spaces in a master password. A backslash is excluded as well because it is easy to mangle
# when a password is copied into a shell or a connection string.
EXCLUDED_CHARACTERS = "/@\"' \\"
PASSWORD_LENGTH = 32

_secrets = None
_rds = None


def _secrets_client():
    global _secrets
    if _secrets is None:
        import boto3

        _secrets = boto3.client("secretsmanager")
    return _secrets


def _rds_client():
    global _rds
    if _rds is None:
        import boto3

        _rds = boto3.client("rds")
    return _rds


def lambda_handler(event, context):
    arn = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]
    secrets = _secrets_client()

    metadata = secrets.describe_secret(SecretId=arn)
    if not metadata.get("RotationEnabled"):
        raise ValueError(f"Rotation is not enabled for secret {arn}")

    versions = metadata.get("VersionIdsToStages", {})
    if token not in versions:
        raise ValueError(f"Version {token} has no stage for rotation of secret {arn}")
    if "AWSCURRENT" in versions[token]:
        logger.info("Version %s is already AWSCURRENT: nothing to do", token)
        return
    if "AWSPENDING" not in versions[token]:
        raise ValueError(f"Version {token} is not AWSPENDING for rotation of secret {arn}")

    steps = {
        "createSecret": create_secret,
        "setSecret": set_secret,
        "testSecret": test_secret,
        "finishSecret": finish_secret,
    }
    if step not in steps:
        raise ValueError(f"Unknown rotation step: {step}")
    steps[step](arn, token)


def create_secret(arn, token):
    """Generate the new password and store it as the pending version (once)."""
    secrets = _secrets_client()
    current = json.loads(secrets.get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")["SecretString"])
    try:
        secrets.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")
        logger.info("createSecret: the pending version already exists")
        return
    except secrets.exceptions.ResourceNotFoundException:
        pass

    password = secrets.get_random_password(
        PasswordLength=PASSWORD_LENGTH, ExcludeCharacters=EXCLUDED_CHARACTERS
    )["RandomPassword"]
    current["password"] = password
    secrets.put_secret_value(
        SecretId=arn,
        ClientRequestToken=token,
        SecretString=json.dumps(current),
        VersionStages=["AWSPENDING"],
    )
    logger.info("createSecret: stored a new pending version")


def _pending(arn, token):
    secrets = _secrets_client()
    return json.loads(
        secrets.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")["SecretString"]
    )


def set_secret(arn, token):
    """Change the cluster's master password to the pending one (control plane, no database login)."""
    pending = _pending(arn, token)
    cluster = pending["dbClusterIdentifier"]
    _rds_client().modify_db_cluster(
        DBClusterIdentifier=cluster,
        MasterUserPassword=pending["password"],
        ApplyImmediately=True,
    )
    logger.info("setSecret: asked RDS to change the master password of cluster %s", cluster)


def test_secret(arn, token):
    """The cluster must be available and the password change applied (no login is possible, see the module note)."""
    pending = _pending(arn, token)
    cluster = pending["dbClusterIdentifier"]
    clusters = _rds_client().describe_db_clusters(DBClusterIdentifier=cluster)["DBClusters"]
    if not clusters:
        raise ValueError(f"Cluster {cluster} was not found")
    state = clusters[0]
    if state.get("Status") != "available":
        # Raising makes Secrets Manager retry this step later
        raise RuntimeError(f"Cluster {cluster} is {state.get('Status')}, not available yet")
    if "MasterUserPassword" in (state.get("PendingModifiedValues") or {}):
        raise RuntimeError(f"The password change on cluster {cluster} has not been applied yet")
    logger.info("testSecret: cluster %s is available and the change is applied", cluster)


def finish_secret(arn, token):
    """Make the pending version the current one."""
    secrets = _secrets_client()
    metadata = secrets.describe_secret(SecretId=arn)
    current_version = None
    for version, stages in metadata["VersionIdsToStages"].items():
        if "AWSCURRENT" in stages:
            if version == token:
                logger.info("finishSecret: version %s is already AWSCURRENT", token)
                return
            current_version = version
            break
    secrets.update_secret_version_stage(
        SecretId=arn,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current_version,
    )
    logger.info("finishSecret: version %s is now AWSCURRENT", token)
