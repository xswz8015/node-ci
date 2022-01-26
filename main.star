#!/usr/bin/env lucicfg

lucicfg.check_version("1.30.4", "Please update depot_tools")

# Launch 100% of Swarming tasks for builds in "realms-aware mode"
luci.builder.defaults.experiments.set({"luci.use_realms": 100})

lucicfg.config(
    config_dir = "generated",
    tracked_files = [
        "commit-queue.cfg",
        "cr-buildbucket.cfg",
        "luci-logdog.cfg",
        "luci-milo.cfg",
        "luci-scheduler.cfg",
        "project.cfg",
        "realms.cfg",
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
    bindings = [
        luci.binding(
            roles = "role/swarming.poolOwner",
            groups = "mdb/v8-infra",
        ),
        luci.binding(
            roles = "role/swarming.poolViewer",
            groups = "all",
        ),
    ],
)

## Swarming permissions

# Allow admins to use LED and "Debug" button on every V8 builder and bot.
luci.binding(
    realm = "@root",
    roles = "role/swarming.poolUser",
    groups = "mdb/v8-infra",
)
luci.binding(
    realm = "@root",
    roles = "role/swarming.taskTriggerer",
    groups = "mdb/v8-infra",
)

# Allow cria/project-v8-led-users to use LED and "Debug" button on
# try and ci builders
def led_users(*, pool_realm, builder_realms, groups):
    luci.realm(
        name = pool_realm,
        bindings = [luci.binding(
            realm = pool_realm,
            roles = "role/swarming.poolUser",
            groups = groups,
        )],
    )
    for br in builder_realms:
        luci.binding(
            realm = br,
            roles = "role/swarming.taskTriggerer",
            groups = groups,
        )

led_users(
    pool_realm = "pools/ci",
    builder_realms = ["ci"],
    groups = "project-v8-admins",
)

led_users(
    pool_realm = "pools/try",
    builder_realms = ["try"],
    groups = "project-v8-admins",
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

luci.binding(
    realm = "@root",
    roles = "role/configs.validator",
    users = TRY_ACCOUNT,
)

###############################################################################
# Milo: CI and Tryserver

REPO = "https://chromium.googlesource.com/v8/node-ci"
V8_ICON = "https://storage.googleapis.com/chrome-infra-public/logo/v8.ico"
V8_LOGO = "https://storage.googleapis.com/chrome-infra-public/logo/v8.svg"
MAIN_REF = "refs/heads/main"

luci.milo(logo = V8_LOGO)

luci.console_view(
    name = "main",
    title = "Main",
    repo = REPO,
    refs = [MAIN_REF],
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
    refs = [MAIN_REF],
)

###############################################################################
# CQ for main and infra/config

luci.cq(
    submit_max_burst = 1,
    submit_burst_delay = 60 * time.second,
    status_host = "chromium-cq-status.appspot.com",
)

def cq_group(name, refs):
    luci.cq_group(
        name = name,
        watch = cq.refset(
            repo = REPO,
            refs = refs,
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

cq_group("main", [MAIN_REF])
cq_group("infra_config", ["refs/heads/infra/config"])

###############################################################################
# Helpers

BUILD = "infra/recipe_bundles/chromium.googlesource.com/chromium/tools/build"

def recipe(name):
    return luci.recipe(
        name = name,
        cipd_package = BUILD,
        cipd_version = MAIN_REF,
        use_bbagent = True,
    )

def goma_args(*, enable_ats = False):
    args = {
        "$build/goma": {
            "server_host": "goma.chromium.org",
            "rpc_extra_params": "?prod",
            "use_luci_auth": True,
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

def ci_builder(*, name, os, properties, **kwargs):
    luci.builder(
        name = name,
        bucket = "ci",
        service_account = CI_ACCOUNT,
        dimensions = dict(os = os, pool = "luci.node-ci.ci"),
        properties = dict(properties, builder_group = "client.node-ci"),
        triggered_by = ["main"],
        **dict(DEFAULT_ARGS, **kwargs)
    )

def try_builder(*, name, os, properties, **kwargs):
    luci.builder(
        name = name,
        bucket = "try",
        service_account = TRY_ACCOUNT,
        dimensions = dict(os = os, pool = "luci.node-ci.try"),
        properties = dict(properties, builder_group = "tryserver.node-ci"),
        **dict(DEFAULT_ARGS, **kwargs)
    )

def builder_pair(*, ci_name, try_name, os, goma = None, cq = False, is_debug = False):
    """Add a CI/trybot pair for a given OS."""
    ci_builder(
        name = ci_name,
        os = os,
        properties = dict(goma or {}, is_debug = is_debug),
        execution_timeout = time.hour,
    )
    luci.console_view_entry(builder = ci_name, console_view = "main")

    try_builder(
        name = try_name,
        os = os,
        properties = dict(goma or {}, is_debug = is_debug),
        execution_timeout = time.hour // 2,
    )
    luci.list_view_entry(builder = try_name, list_view = "tryserver")

    if cq:
        luci.cq_tryjob_verifier(builder = try_name, cq_group = "main")

###############################################################################
# Standard builders

builder_pair(
    ci_name = "Node-CI Linux64",
    try_name = "node_ci_linux64_rel",
    os = "Ubuntu",
    goma = GOMA_DEFAULT,
    cq = True,
)

builder_pair(
    ci_name = "Node-CI Linux64 - debug",
    try_name = "node_ci_linux64_dbg",
    os = "Ubuntu",
    goma = GOMA_DEFAULT,
    is_debug = True,
)

builder_pair(
    ci_name = "Node-CI Mac64",
    try_name = "node_ci_mac64_rel",
    os = "Mac",
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
    os = "Ubuntu",
    properties = {"runhooks": False, "solution_name": "node-ci"},
    execution_timeout = 5 * time.minute,
    priority = 25,
)

luci.cq_tryjob_verifier(
    builder = "node_ci_presubmit",
    cq_group = "main",
    disable_reuse = True,
)
luci.cq_tryjob_verifier(
    builder = "node_ci_presubmit",
    cq_group = "infra_config",
    disable_reuse = True,
)

luci.list_view_entry(builder = "node_ci_presubmit", list_view = "tryserver")
