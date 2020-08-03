#!/usr/bin/env lucicfg

lucicfg.check_version("1.17.0")

lucicfg.config(
    config_dir = "generated",
    tracked_files = [
        "commit-queue.cfg",
        "cr-buildbucket.cfg",
        "luci-logdog.cfg",
        "luci-milo.cfg",
        "luci-scheduler.cfg",
        "project.cfg",
    ],
    fail_on_warnings = True,
    lint_checks = [
        "default",
        "-function-docstring",
        "-function-docstring-args",
        "-function-docstring-return",
        "-module-docstring",
    ],
)

###############################################################################
# Project

luci.project(
    name = "node-ci",
    buildbucket = "cr-buildbucket.appspot.com",
    logdog = "luci-logdog",
    milo = "luci-milo",
    scheduler = "luci-scheduler",
    swarming = "chromium-swarm.appspot.com",
    acls = [
        acl.entry(
            [
                acl.BUILDBUCKET_READER,
                acl.LOGDOG_READER,
                acl.PROJECT_CONFIGS_READER,
                acl.SCHEDULER_READER,
            ],
            groups = ["all"],
        ),
        acl.entry([acl.SCHEDULER_OWNER], groups = ["project-v8-admins"]),
        acl.entry(
            [acl.LOGDOG_WRITER],
            groups = ["luci-logdog-chromium-writers"],
        ),
    ],
)

luci.logdog(gs_bucket = "chromium-luci-logdog")

###############################################################################
# Buckets: CI and Try

CI_ACCOUNT = "node-ci-ci-builder@chops-service-accounts.iam.gserviceaccount.com"
TRY_ACCOUNT = "node-ci-try-builder@chops-service-accounts.iam.gserviceaccount.com"
SCHEDULER_ACCOUNT = "luci-scheduler@appspot.gserviceaccount.com"

READER_ACL = acl.entry(
    roles = acl.BUILDBUCKET_READER,
    groups = "all",
)

luci.bucket(
    name = "ci",
    acls = [
        READER_ACL,
        acl.entry(
            roles = acl.BUILDBUCKET_TRIGGERER,
            users = [CI_ACCOUNT, SCHEDULER_ACCOUNT],
        ),
    ],
)

luci.bucket(
    name = "try",
    acls = [
        READER_ACL,
        acl.entry(
            roles = acl.BUILDBUCKET_TRIGGERER,
            groups = ["service-account-cq", "project-v8-tryjob-access"],
            projects = ["v8"],
        ),
    ],
)

###############################################################################
# Milo: CI and Tryserver

REPO = "https://chromium.googlesource.com/v8/node-ci"
V8_ICON = "https://storage.googleapis.com/chrome-infra-public/logo/v8.ico"
V8_LOGO = "https://storage.googleapis.com/chrome-infra-public/logo/v8.svg"
MASTER_REF = "refs/heads/master"

luci.milo(logo = V8_LOGO)

luci.console_view(
    name = "main",
    title = "Main",
    repo = REPO,
    refs = [MASTER_REF],
    favicon = V8_ICON,
)

luci.list_view(
    name = "tryserver",
    title = "Tryserver",
    favicon = V8_ICON,
)

###############################################################################
# Scheduler

luci.gitiles_poller(
    name = "main",
    bucket = "ci",
    repo = REPO,
    refs = [MASTER_REF],
)

###############################################################################
# CQ for master and infra/config

luci.cq(
    # TODO(tandrii): undo submit_max_burst to 1.
    submit_max_burst = 2,
    submit_burst_delay = 60 * time.second,
    status_host = "chromium-cq-status.appspot.com",
)

def cq_group(name, ref):
    luci.cq_group(
        name = name,
        watch = cq.refset(
            repo = REPO,
            refs = [ref],
        ),
        acls = [
            acl.entry(
                [acl.CQ_COMMITTER],
                groups = ["project-v8-committers"],
            ),
            acl.entry(
                [acl.CQ_DRY_RUNNER],
                groups = ["project-v8-tryjob-access"],
            ),
        ],
        retry_config = cq.retry_config(
            single_quota = 2,
            global_quota = 4,
            failure_weight = 2,
            transient_failure_weight = 1,
            timeout_weight = 4,
        ),
    )

cq_group("master", MASTER_REF)
cq_group("infra_config", "refs/heads/infra/config")

###############################################################################
# Helpers

BUILD = "infra/recipe_bundles/chromium.googlesource.com/chromium/tools/build"

def recipe(name):
    return luci.recipe(
        name = name,
        cipd_package = BUILD,
        cipd_version = MASTER_REF,
    )

def goma_args(*, enable_ats = False):
    args = {
        "$build/goma": {
            "server_host": "goma.chromium.org",
            "rpc_extra_params": "?prod",
        },
    }
    if enable_ats:
        args["$build/goma"]["enable_ats"] = True
    return args

GOMA_DEFAULT = goma_args()
GOMA_ATS = goma_args(enable_ats = True)

DEFAULT_ARGS = {
    "executable": recipe("v8/node_integration_ng"),
    "swarming_tags": ["vpython:native-python-wrapper"],
}

def ci_builder(*, name, properties, **kvargs):
    luci.builder(
        name = name,
        bucket = "ci",
        service_account = CI_ACCOUNT,
        properties = dict(properties, mastername = "client.node-ci"),
        triggered_by = ["main"],
        **dict(DEFAULT_ARGS, **kvargs)
    )

def try_builder(*, name, properties, **kvargs):
    luci.builder(
        name = name,
        bucket = "try",
        service_account = TRY_ACCOUNT,
        properties = dict(properties, mastername = "tryserver.node-ci"),
        **dict(DEFAULT_ARGS, **kvargs)
    )

def builder_pair(*, ci_name, try_name, os, goma = None, cq = False):
    """Add a CI/trybot pair for a given OS."""
    ci_builder(
        name = ci_name,
        properties = dict(goma or {}),
        dimensions = dict(os = os),
        execution_timeout = time.hour,
    )
    luci.console_view_entry(builder = ci_name, console_view = "main")

    try_builder(
        name = try_name,
        properties = dict(goma or {}),
        dimensions = dict(os = os),
        execution_timeout = time.hour // 2,
    )
    luci.list_view_entry(builder = try_name, list_view = "tryserver")

    if cq:
        luci.cq_tryjob_verifier(builder = try_name, cq_group = "master")

###############################################################################
# Standard builders

builder_pair(
    ci_name = "Node-CI Linux64",
    try_name = "node_ci_linux64_rel",
    os = "Ubuntu-16.04",
    goma = GOMA_DEFAULT,
    cq = True,
)

builder_pair(
    ci_name = "Node-CI Mac64",
    try_name = "node_ci_mac64_rel",
    os = "Mac-10.13",
)

builder_pair(
    ci_name = "Node-CI Win64",
    try_name = "node_ci_win64_rel",
    os = "Windows-10",
    goma = GOMA_ATS,
)

###############################################################################
# Non-standard builders

try_builder(
    name = "node_ci_presubmit",
    executable = recipe("run_presubmit"),
    dimensions = {"os": "Ubuntu-16.04", "pool": "try"},
    properties = {"runhooks": False, "solution_name": "node-ci"},
    execution_timeout = 5 * time.minute,
    priority = 25,
)

luci.cq_tryjob_verifier(
    builder = "node_ci_presubmit",
    cq_group = "master",
    disable_reuse = True,
)
luci.cq_tryjob_verifier(
    builder = "node_ci_presubmit",
    cq_group = "infra_config",
    disable_reuse = True,
)

luci.list_view_entry(builder = "node_ci_presubmit", list_view = "tryserver")
