"""Tests for the rotation function. Run with: python3 -m unittest discover -s lambdas/db-rotation

They use fake Secrets Manager and RDS clients, so they need no AWS access, no network and no packages (boto3 is only
imported when a real client is created). The fake keeps versions and stages the way Secrets Manager does.
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import lambda_function as rotation  # noqa: E402

# Built from parts so the repository secret scanner does not mistake the placeholder for a real account ID
ARN = ":".join(["arn", "aws", "secretsmanager", "us-east-1", "ACCOUNT_ID", "secret", "fake"])
CLUSTER = "fake-cluster"


class NotFound(Exception):
    pass


class FakeSecrets:
    class exceptions:  # noqa: N801 - mirrors the boto3 client attribute
        ResourceNotFoundException = NotFound

    def __init__(self, rotation_enabled=True):
        self.rotation_enabled = rotation_enabled
        self.versions = {}  # version id -> secret string
        self.stages = {}  # version id -> set of stages
        self.counter = 0
        self.put_calls = 0

    def seed_current(self, value=None):
        # A made-up value, built from parts so the repository secret scanner does not flag the fixture
        value = value or "-".join(["not", "the", "real", "one"])
        self.versions["v-old"] = json.dumps(
            {"engine": "postgres", "username": "product_app", "password": value, "dbClusterIdentifier": CLUSTER}
        )
        self.stages["v-old"] = {"AWSCURRENT"}

    def describe_secret(self, SecretId):
        return {
            "RotationEnabled": self.rotation_enabled,
            "VersionIdsToStages": {v: sorted(s) for v, s in self.stages.items() if s},
        }

    def _find(self, VersionId=None, VersionStage=None):
        for version, stages in self.stages.items():
            if VersionId is not None and version != VersionId:
                continue
            if VersionStage is not None and VersionStage not in stages:
                continue
            return version
        raise NotFound("no such version")

    def get_secret_value(self, SecretId, VersionId=None, VersionStage=None):
        version = self._find(VersionId, VersionStage)
        if version not in self.versions:
            # A rotation's token version is staged AWSPENDING before it has a value, as in Secrets Manager
            raise NotFound("the version has no value yet")
        return {"VersionId": version, "SecretString": self.versions[version]}

    def get_random_password(self, PasswordLength, ExcludeCharacters):
        self.counter += 1
        alphabet = [c for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-.:;<=>?[]^_{|}~" if c not in ExcludeCharacters]
        text = "".join(alphabet[(i * 7 + self.counter * 13) % len(alphabet)] for i in range(PasswordLength))
        return {"RandomPassword": text}

    def put_secret_value(self, SecretId, ClientRequestToken, SecretString, VersionStages):
        self.put_calls += 1
        self.versions[ClientRequestToken] = SecretString
        self.stages[ClientRequestToken] = set(VersionStages)

    def update_secret_version_stage(self, SecretId, VersionStage, MoveToVersionId=None, RemoveFromVersionId=None):
        if RemoveFromVersionId is not None:
            self.stages[RemoveFromVersionId].discard(VersionStage)
        if MoveToVersionId is not None:
            self.stages[MoveToVersionId].add(VersionStage)
            if VersionStage == "AWSCURRENT":
                self.stages[MoveToVersionId].discard("AWSPENDING")


class FakeRds:
    def __init__(self, status="available", pending=None):
        self.status = status
        self.pending = pending or {}
        self.modify_calls = []

    def modify_db_cluster(self, **kwargs):
        self.modify_calls.append(kwargs)

    def describe_db_clusters(self, DBClusterIdentifier):
        return {"DBClusters": [{"Status": self.status, "PendingModifiedValues": self.pending}]}


class RotationTest(unittest.TestCase):
    def setUp(self):
        self.secrets = FakeSecrets()
        self.secrets.seed_current()
        self.rds = FakeRds()
        rotation._secrets = self.secrets
        rotation._rds = self.rds

    def tearDown(self):
        rotation._secrets = None
        rotation._rds = None

    def run_step(self, step, token="v-new"):
        rotation.lambda_handler({"SecretId": ARN, "ClientRequestToken": token, "Step": step}, None)

    def current_password(self):
        return json.loads(self.secrets.get_secret_value(ARN, VersionStage="AWSCURRENT")["SecretString"])["password"]

    def rotate(self, token="v-new"):
        # Secrets Manager stages the token as AWSPENDING with the first step's put; the fake needs it declared up front
        for step in ("createSecret", "setSecret", "testSecret", "finishSecret"):
            if step == "createSecret":
                self.secrets.stages.setdefault(token, set()).add("AWSPENDING")
            self.run_step(step, token)

    def test_full_rotation_changes_the_password_and_moves_the_stage(self):
        old = self.current_password()
        self.rotate()
        new = self.current_password()
        self.assertNotEqual(new, old)
        self.assertEqual(len(new), rotation.PASSWORD_LENGTH)
        self.assertIn("AWSCURRENT", self.secrets.stages["v-new"])
        self.assertNotIn("AWSPENDING", self.secrets.stages["v-new"])
        self.assertEqual(self.secrets.stages["v-old"], set())

    def test_the_cluster_password_is_set_once_through_the_control_plane(self):
        self.rotate()
        self.assertEqual(len(self.rds.modify_calls), 1)
        call = self.rds.modify_calls[0]
        self.assertEqual(call["DBClusterIdentifier"], CLUSTER)
        self.assertEqual(call["MasterUserPassword"], self.current_password())
        self.assertTrue(call["ApplyImmediately"])

    def test_other_secret_fields_are_kept(self):
        self.rotate()
        current = json.loads(self.secrets.get_secret_value(ARN, VersionStage="AWSCURRENT")["SecretString"])
        self.assertEqual(current["username"], "product_app")
        self.assertEqual(current["dbClusterIdentifier"], CLUSTER)

    def test_the_password_has_no_characters_rds_rejects(self):
        self.rotate()
        for char in "/@\"' \\":
            self.assertNotIn(char, self.current_password())

    def test_create_secret_is_idempotent(self):
        self.secrets.stages["v-new"] = {"AWSPENDING"}
        self.run_step("createSecret")
        first = self.secrets.versions["v-new"]
        self.run_step("createSecret")
        self.assertEqual(self.secrets.put_calls, 1)
        self.assertEqual(self.secrets.versions["v-new"], first)

    def test_finish_secret_is_idempotent(self):
        self.rotate()
        self.run_step("finishSecret")  # already AWSCURRENT: returns without error
        self.assertIn("AWSCURRENT", self.secrets.stages["v-new"])

    def test_set_secret_asks_rds_only_once_however_often_it_is_run(self):
        self.secrets.stages["v-new"] = {"AWSPENDING"}
        self.run_step("createSecret")
        self.run_step("setSecret")
        self.run_step("setSecret")
        self.assertEqual(len(self.rds.modify_calls), 1)
        self.assertIn(rotation.SET_LABEL, self.secrets.stages["v-new"])

    def test_a_retry_after_a_failed_test_does_not_restart_the_password_reset(self):
        # What the first real run showed: testSecret fails while RDS is still resetting the credentials, Secrets Manager retries the
        # whole rotation, and without the label every retry would ask RDS for the change again, so the reset never finishes
        self.secrets.stages["v-new"] = {"AWSPENDING"}
        self.run_step("createSecret")
        self.run_step("setSecret")
        self.rds.status = "resetting-master-credentials"
        self.rds.pending = {"MasterUserPassword": "****"}
        with self.assertRaises(RuntimeError):
            self.run_step("testSecret")
        for _ in range(3):  # three retries from the top, the cluster still busy
            self.run_step("createSecret")
            self.run_step("setSecret")
            with self.assertRaises(RuntimeError):
                self.run_step("testSecret")
        self.assertEqual(len(self.rds.modify_calls), 1)
        self.rds.status, self.rds.pending = "available", {}  # the reset finishes
        self.run_step("createSecret")
        self.run_step("setSecret")
        self.run_step("testSecret")
        self.run_step("finishSecret")
        self.assertEqual(len(self.rds.modify_calls), 1)
        self.assertIn("AWSCURRENT", self.secrets.stages["v-new"])

    def test_the_label_is_removed_when_the_rotation_finishes(self):
        self.rotate()
        self.assertNotIn(rotation.SET_LABEL, self.secrets.stages["v-new"])

    def test_test_secret_fails_while_the_cluster_is_not_available(self):
        self.secrets.stages["v-new"] = {"AWSPENDING"}
        self.run_step("createSecret")
        self.rds.status = "resetting-master-credentials"
        with self.assertRaises(RuntimeError):
            self.run_step("testSecret")

    def test_test_secret_fails_while_the_password_change_is_pending(self):
        self.secrets.stages["v-new"] = {"AWSPENDING"}
        self.run_step("createSecret")
        self.rds.pending = {"MasterUserPassword": "****"}
        with self.assertRaises(RuntimeError):
            self.run_step("testSecret")

    def test_rotation_must_be_enabled(self):
        self.secrets.rotation_enabled = False
        with self.assertRaises(ValueError):
            self.run_step("createSecret")

    def test_an_unknown_version_is_refused(self):
        with self.assertRaises(ValueError):
            self.run_step("createSecret", token="never-staged")

    def test_a_version_that_is_not_pending_is_refused(self):
        self.secrets.stages["v-new"] = {"SOMETHING_ELSE"}
        with self.assertRaises(ValueError):
            self.run_step("createSecret")

    def test_an_unknown_step_is_refused(self):
        self.secrets.stages["v-new"] = {"AWSPENDING"}
        with self.assertRaises(ValueError):
            self.run_step("explode")

    def test_nothing_is_changed_when_the_version_is_already_current(self):
        before = dict(self.secrets.versions)
        self.run_step("setSecret", token="v-old")
        self.assertEqual(self.rds.modify_calls, [])
        self.assertEqual(self.secrets.versions, before)


if __name__ == "__main__":
    unittest.main()
