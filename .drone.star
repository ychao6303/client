#
# We are building GCC with make and Clang with ninja, the combinations are more
# or less arbitrarily chosen. We just want to check that both compilers and both
# CMake generators work. It's unlikely that a specific generator only breaks
# with a specific compiler.
#

DEFAULT_PHP_VERSION = "7.4"

CYTOPIA_BLACK = "cytopia/black"
DOCKER_GIT = "docker:git"
MYSQL = "mysql:8.0"
OC_CI_ALPINE = "owncloudci/alpine:latest"
OC_CI_BAZEL_BUILDIFIER = "owncloudci/bazel-buildifier"
OC_CI_CLIENT = "owncloudci/client:latest"
OC_CI_CORE = "owncloudci/core"
OC_CI_DRONE_CANCEL_PREVIOUS_BUILDS = "owncloudci/drone-cancel-previous-builds"
OC_CI_DRONE_SKIP_PIPELINE = "owncloudci/drone-skip-pipeline"
OC_CI_NODEJS = "owncloudci/nodejs:16"
OC_CI_PHP = "owncloudci/php:%s"
OC_CI_TRANSIFEX = "owncloudci/transifex:latest"
OC_CI_WAIT_FOR = "owncloudci/wait-for:latest"
OC_OCIS = "owncloud/ocis:%s"
OC_TEST_MIDDLEWARE = "owncloud/owncloud-test-middleware:1.8.3"
OC_UBUNTU = "owncloud/ubuntu:20.04"

# Eventually, we have to use image built on ubuntu
# Todo: update or remove the following images
# https://github.com/owncloud/client/issues/10070
OC_CI_CLIENT_FEDORA = "owncloudci/client:fedora-36-amd64"
OC_CI_SQUISH = "owncloudci/squish:fedora-36-6.7-20220106-1008-qt515x-linux64"

PLUGINS_GIT_ACTION = "plugins/git-action:1"
PLUGINS_S3 = "plugins/s3"
PLUGINS_SLACK = "plugins/slack"
PYTHON = "python"
THEGEEKLAB_DRONE_GITHUB_COMMENT = "thegeeklab/drone-github-comment:1"
TOOLHIPPIE_CALENS = "toolhippie/calens:latest"

dir = {
    "base": "/drone/src",
    "server": "/drone/src/server",
    "guiTest": "/drone/src/test/gui",
    "guiTestReport": "/drone/src/test/guiReportUpload",
    "build": "/drone/src/build",
}

notify_channels = {
    "desktop-internal": {
        "type": "channel",
    },
}

branch_ref = [
    "refs/heads/master",
    "refs/heads/4**",
]

trigger_ref = branch_ref + [
    "refs/tags/**",
    "refs/pull/**",
]

build_config = {
    "c_compiler": "clang",
    "cxx_compiler": "clang++",
    "build_type": "Debug",
    "generator": "Ninja",
    "command": "ninja",
}

config = {
    "gui-tests": {
        "servers": {
            "oc10": {
                "version": "latest",
                # comma separated list of tags to be used for filtering. E.g. "@tag1,@tag2"
                "tags": "~@skipOnOC10",
                "extra_apps": {
                    "oauth2": {
                        "enabled": False,
                        "command": "make dist",
                    },
                },
                "skip_in_pr": True,
            },
            "ocis": {
                "version": "2.0.0",
                # comma separated list of tags to be used for filtering. E.g. "@tag1,@tag2"
                "tags": "~@skipOnOCIS",
            },
        },
    },
}

def main(ctx):
    pipelines = cancelPreviousBuilds() + \
                check_starlark() + \
                gui_tests_format() + \
                changelog(ctx)
    unit_tests = unit_test_pipeline(ctx)
    gui_tests = gui_test_pipeline(ctx)

    return pipelines + \
           unit_tests + \
           gui_tests + \
           pipelinesDependsOn(notification(), unit_tests + gui_tests)

def from_secret(name):
    return {
        "from_secret": name,
    }

def check_starlark():
    return [{
        "kind": "pipeline",
        "type": "docker",
        "name": "check-starlark",
        "steps": [
            {
                "name": "format-check-starlark",
                "image": OC_CI_BAZEL_BUILDIFIER,
                "commands": [
                    "buildifier --mode=check .drone.star",
                ],
            },
            {
                "name": "show-diff",
                "image": OC_CI_BAZEL_BUILDIFIER,
                "commands": [
                    "buildifier --mode=fix .drone.star",
                    "git diff",
                ],
                "when": {
                    "status": [
                        "failure",
                    ],
                },
            },
        ],
        "trigger": {
            "event": [
                "pull_request",
            ],
        },
    }]

def unit_test_pipeline(ctx):
    return [{
        "kind": "pipeline",
        "name": "unit-tests",
        "platform": {
            "os": "linux",
            "arch": "amd64",
        },
        "steps": skipIfUnchanged(ctx, "unit-tests") +
                 build_client() +
                 unit_tests(),
        "trigger": {
            "ref": trigger_ref,
        },
    }]

def gui_test_pipeline(ctx):
    squish_parameters = "--reportgen html,%s --envvar QT_LOGGING_RULES=sync.httplogger=true;gui.socketapi=false  --tags ~@skip" % dir["guiTestReport"]
    pipelines = []
    for server, params in config["gui-tests"]["servers"].items():
        if ctx.build.event == "pull_request" and params.get("skip_in_pr", False) and not "full-ci" in ctx.build.title.lower():
            continue

        # also skip in commit push
        if params.get("skip_in_pr", False) and ctx.build.event == "push":
            continue

        pipeline_name = "GUI-tests-%s" % server

        if params["tags"]:
            squish_parameters += " --tags %s" % params["tags"]

        steps = skipIfUnchanged(ctx, "gui-tests") + \
                build_client(OC_CI_CLIENT_FEDORA, False)

        services = testMiddlewareService(server)

        if server == "oc10":
            steps += installCore(params["version"]) + \
                     setupServerAndApp() + \
                     installExtraApps(params["extra_apps"]) + \
                     fixPermissions() + \
                     owncloudLog()
            services += owncloudService() + \
                        databaseService()
        else:
            steps += ocisService(params["version"]) + \
                     waitForOcisService()

        steps += installPnpm() + \
                 setGuiTestReportDir() + \
                 gui_tests(squish_parameters, server) + \
                 uploadGuiTestLogs(ctx, server) + \
                 buildGithubComment(pipeline_name, server) + \
                 githubComment(pipeline_name, server)

        pipelines.append({
            "kind": "pipeline",
            "name": pipeline_name,
            "platform": {
                "os": "linux",
                "arch": "amd64",
            },
            "steps": steps,
            "services": services,
            "trigger": {
                "ref": trigger_ref,
            },
            "volumes": [
                {
                    "name": "uploads",
                    "temp": {},
                },
            ],
        })
    return pipelines

def build_client(image = OC_CI_CLIENT, ctest = True):
    cmake_options = '-G"%s" -DCMAKE_C_COMPILER="%s" -DCMAKE_CXX_COMPILER="%s" -DCMAKE_BUILD_TYPE="%s" -DWITH_LIBCLOUDPROVIDERS=ON'
    cmake_options = cmake_options % (build_config["generator"], build_config["c_compiler"], build_config["cxx_compiler"], build_config["build_type"])

    if ctest:
        cmake_options += " -DBUILD_TESTING=ON"
    else:
        cmake_options += " -DBUILD_TESTING=OFF"

    return [
        {
            "name": "build-client",
            "image": image,
            "environment": {
                "LC_ALL": "C.UTF-8",
            },
            "commands": [
                "git submodule update --init --recursive",
                "mkdir -p %s" % dir["build"],
                "cd %s" % dir["build"],
                # generate build files
                "cmake %s -S .." % cmake_options,
                # build
                build_config["command"],
            ],
        },
    ]

def unit_tests():
    return [{
        "name": "ctest",
        "image": OC_CI_CLIENT,
        "environment": {
            "LC_ALL": "C.UTF-8",
        },
        "commands": [
            "cd %s" % dir["build"],
            "useradd -m -s /bin/bash tester",
            "chown -R tester:tester .",
            "su-exec tester ctest --output-on-failure -LE nodrone",
        ],
    }]

def gui_tests(squish_parameters = "", server_type = "oc10"):
    return [{
        "name": "GUItests",
        "image": OC_CI_SQUISH,
        "environment": {
            "LICENSEKEY": from_secret("squish_license_server"),
            "GUI_TEST_REPORT_DIR": dir["guiTestReport"],
            "CLIENT_REPO": dir["base"],
            "MIDDLEWARE_URL": "http://testmiddleware:3000/",
            "BACKEND_HOST": "http://owncloud/" if server_type == "oc10" else "https://ocis:9200",
            "SECURE_BACKEND_HOST": "https://owncloud/" if server_type == "oc10" else "https://ocis:9200",
            "OCIS": "true" if server_type == "ocis" else "false",
            "SERVER_INI": "%s/drone/server.ini" % dir["guiTest"],
            "SQUISH_PARAMETERS": squish_parameters,
            "STACKTRACE_FILE": "%s/stacktrace.log" % dir["guiTestReport"],
            "PLAYWRIGHT_BROWSERS_PATH": "%s/.playwright" % dir["base"],
            "OWNCLOUD_CORE_DUMP": 1,
        },
    }]

def gui_tests_format():
    return [{
        "kind": "pipeline",
        "type": "docker",
        "name": "guitestformat",
        "steps": [
            {
                "name": "black",
                "image": CYTOPIA_BLACK,
                "commands": [
                    "cd %s" % dir["guiTest"],
                    "black --check --diff .",
                ],
            },
        ],
        "trigger": {
            "event": [
                "pull_request",
            ],
        },
    }]

def changelog(ctx):
    repo_slug = ctx.build.source_repo if ctx.build.source_repo else ctx.repo.slug

    return [{
        "kind": "pipeline",
        "type": "docker",
        "name": "changelog",
        "clone": {
            "disable": True,
        },
        "steps": [
            {
                "name": "clone",
                "image": PLUGINS_GIT_ACTION,
                "settings": {
                    "actions": [
                        "clone",
                    ],
                    "remote": "https://github.com/%s" % (repo_slug),
                    "branch": ctx.build.source if ctx.build.event == "pull_request" else "master",
                    "path": dir["base"],
                    "netrc_machine": "github.com",
                    "netrc_username": from_secret("github_username"),
                    "netrc_password": from_secret("github_token"),
                },
            },
            {
                "name": "generate",
                "image": TOOLHIPPIE_CALENS,
                "commands": [
                    "calens >| CHANGELOG.md",
                ],
            },
            {
                "name": "diff",
                "image": OC_CI_ALPINE,
                "commands": [
                    "git diff",
                ],
            },
            {
                "name": "output",
                "image": TOOLHIPPIE_CALENS,
                "commands": [
                    "cat CHANGELOG.md",
                ],
            },
            {
                "name": "publish",
                "image": PLUGINS_GIT_ACTION,
                "settings": {
                    "actions": [
                        "commit",
                        "push",
                    ],
                    "message": "Automated changelog update [skip ci]",
                    "branch": "master",
                    "author_email": "devops@owncloud.com",
                    "author_name": "ownClouders",
                    "netrc_machine": "github.com",
                    "netrc_username": from_secret("github_username"),
                    "netrc_password": from_secret("github_token"),
                },
                "when": {
                    "ref": {
                        "exclude": [
                            "refs/pull/**",
                            "refs/tags/**",
                        ],
                    },
                },
            },
        ],
        "trigger": {
            "ref": branch_ref + [
                "refs/pull/**",
            ],
        },
    }]

def notification():
    steps = [{
        "name": "create-template",
        "image": OC_CI_ALPINE,
        "environment": {
            "CACHE_ENDPOINT": {
                "from_secret": "cache_public_s3_server",
            },
            "CACHE_BUCKET": {
                "from_secret": "cache_public_s3_bucket",
            },
        },
        "commands": [
            "bash %s/drone/notification_template.sh %s" % (dir["guiTest"], dir["base"]),
        ],
    }]

    for channel, params in notify_channels.items():
        settings = {
            "webhook": from_secret("private_rocketchat"),
            "template": "file:%s/template.md" % dir["base"],
        }
        if params["type"] == "user":
            settings["recipient"] = channel
        else:
            settings["channel"] = channel

        steps.append(
            {
                "name": "notification-%s" % channel,
                "image": PLUGINS_SLACK,
                "settings": settings,
            },
        )

    return [{
        "kind": "pipeline",
        "name": "notifications",
        "platform": {
            "os": "linux",
            "arch": "amd64",
        },
        "steps": steps,
        "trigger": {
            "event": [
                "cron",
                "tag",
            ],
            "status": [
                "success",
                "failure",
            ],
        },
    }]

def databaseService():
    return [{
        "name": "mysql",
        "image": MYSQL,
        "environment": {
            "MYSQL_USER": "owncloud",
            "MYSQL_PASSWORD": "owncloud",
            "MYSQL_DATABASE": "owncloud",
            "MYSQL_ROOT_PASSWORD": "owncloud",
        },
        "command": ["--default-authentication-plugin=mysql_native_password"],
    }]

def installCore(server_version = "latest"):
    return [{
        "name": "install-core",
        "image": OC_CI_CORE,
        "settings": {
            "version": server_version,
            "core_path": dir["server"],
            "db_type": "mysql",
            "db_name": "owncloud",
            "db_host": "mysql",
            "db_username": "owncloud",
            "db_password": "owncloud",
        },
    }]

def setupServerAndApp(logLevel = 2):
    return [{
        "name": "setup-owncloud-server",
        "image": OC_CI_PHP % DEFAULT_PHP_VERSION,
        "commands": [
            "cd %s" % dir["server"],
            "php occ a:e testing",
            "php occ config:system:set trusted_domains 1 --value=owncloud",
            "php occ log:manage --level %s" % logLevel,
            "php occ config:list",
            "php occ config:system:set skeletondirectory --value=/var/www/owncloud/server/apps/testing/data/tinySkeleton",
            "php occ config:system:set sharing.federation.allowHttpFallback --value=true --type=bool",
        ],
    }]

def installExtraApps(extra_apps = {}):
    commands = []
    for app, param in extra_apps.items():
        commands.append("ls %s/apps/%s || git clone --depth 1 https://github.com/owncloud/%s.git %s/apps/%s" % (dir["server"], app, app, dir["server"], app))
        if (param["command"] != ""):
            commands.append("cd %s/apps/%s" % (dir["server"], app))
            commands.append(param["command"])
        if param["enabled"]:
            commands.append("cd %s" % dir["server"])
            commands.append("php occ a:e %s" % app)

    return [{
        "name": "install-extra-apps",
        "image": OC_CI_PHP % DEFAULT_PHP_VERSION,
        "commands": commands,
    }]

def owncloudService():
    return [{
        "name": "owncloud",
        "image": OC_CI_PHP % DEFAULT_PHP_VERSION,
        "environment": {
            "APACHE_WEBROOT": dir["server"],
            "APACHE_CONFIG_TEMPLATE": "ssl",
            "APACHE_SSL_CERT_CN": "server",
            "APACHE_SSL_CERT": "%s/server.crt" % dir["base"],
            "APACHE_SSL_KEY": "%s/server.key" % dir["base"],
            "APACHE_LOGGING_PATH": "/dev/null",
        },
        "commands": [
            "cat /etc/apache2/templates/base >> /etc/apache2/templates/ssl",
            "/usr/local/bin/apachectl -e debug -D FOREGROUND",
        ],
    }]

def testMiddlewareService(server_type = "oc10"):
    environment = {
        "NODE_TLS_REJECT_UNAUTHORIZED": "0",
        "MIDDLEWARE_HOST": "testmiddleware",
        "REMOTE_UPLOAD_DIR": "/uploads",
    }

    if server_type == "ocis":
        environment["BACKEND_HOST"] = "https://ocis:9200"
        environment["TEST_WITH_GRAPH_API"] = "true"
        environment["RUN_ON_OCIS"] = "true"
    else:
        environment["BACKEND_HOST"] = "http://owncloud"

    return [{
        "name": "testmiddleware",
        "image": OC_TEST_MIDDLEWARE,
        "environment": environment,
        "volumes": [{
            "name": "uploads",
            "path": "/uploads",
        }],
    }]

def owncloudLog():
    return [{
        "name": "owncloud-log",
        "image": OC_UBUNTU,
        "detach": True,
        "commands": [
            "tail -f %s/data/owncloud.log" % dir["server"],
        ],
    }]

def fixPermissions():
    return [{
        "name": "fix-permissions",
        "image": OC_CI_PHP % DEFAULT_PHP_VERSION,
        "commands": [
            "cd %s" % dir["server"],
            "chown www-data * -R",
        ],
    }]

def ocisService(server_version = "latest"):
    return [{
        "name": "ocis",
        "image": OC_OCIS % server_version,
        "detach": True,
        "environment": {
            "OCIS_URL": "https://ocis:9200",
            "IDM_ADMIN_PASSWORD": "admin",
            "STORAGE_HOME_DRIVER": "ocis",
            "STORAGE_USERS_DRIVER": "ocis",
            "OCIS_INSECURE": "true",
            "PROXY_ENABLE_BASIC_AUTH": True,
            "OCIS_LOG_LEVEL": "error",
            "OCIS_LOG_PRETTY": "true",
            "OCIS_LOG_COLOR": "true",
        },
        "commands": [
            "/usr/bin/ocis init",
            "/usr/bin/ocis server",
        ],
    }]

def waitForOcisService():
    return [{
        "name": "wait-for-ocis",
        "image": OC_CI_WAIT_FOR,
        "commands": [
            "wait-for -it ocis:9200 -t 300",
        ],
    }]

def installPnpm():
    return [{
        "name": "pnpm-install",
        "image": OC_CI_NODEJS,
        "environment": {
            "PLAYWRIGHT_BROWSERS_PATH": "%s/.playwright" % dir["base"],
            "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD": "true",
        },
        "commands": [
            "cd %s/webUI" % dir["guiTest"],
            "pnpm config set store-dir ./.pnpm-store",
            "pnpm install",
            # install required browser
            "npx playwright install chromium",
        ],
    }]

def setGuiTestReportDir():
    return [{
        "name": "create-gui-test-report-directory",
        "image": OC_UBUNTU,
        "commands": [
            "mkdir %s/screenshots -p" % dir["guiTestReport"],
            "chmod 777 %s -R" % dir["guiTestReport"],
        ],
    }]

def showGuiTestResult():
    return [{
        "name": "show-gui-test-result",
        "image": PYTHON,
        "commands": [
            "python %s/TestLogParser.py %s/results.json" % (dir["guiTest"], dir["guiTestReport"]),
        ],
        "when": {
            "status": [
                "failure",
            ],
        },
    }]

def uploadGuiTestLogs(ctx, server_type = "oc10"):
    trigger = {
        "status": [
            "failure",
        ],
    }
    if ctx.build.event == "tag":
        trigger["status"].append("success")

    return [{
        "name": "upload-gui-test-result",
        "image": PLUGINS_S3,
        "settings": {
            "bucket": {
                "from_secret": "cache_public_s3_bucket",
            },
            "endpoint": {
                "from_secret": "cache_public_s3_server",
            },
            "path_style": True,
            "source": "%s/**/*" % dir["guiTestReport"],
            "strip_prefix": "%s" % dir["guiTestReport"],
            "target": "/${DRONE_REPO}/${DRONE_BUILD_NUMBER}/%s/guiReportUpload" % server_type,
        },
        "environment": {
            "AWS_ACCESS_KEY_ID": {
                "from_secret": "cache_public_s3_access_key",
            },
            "AWS_SECRET_ACCESS_KEY": {
                "from_secret": "cache_public_s3_secret_key",
            },
        },
        "when": trigger,
    }]

def buildGithubComment(suite = "", server_type = "oc10"):
    return [{
        "name": "build-github-comment",
        "image": OC_UBUNTU,
        "commands": [
            "bash %s/drone/comment.sh %s ${DRONE_REPO} ${DRONE_BUILD_NUMBER} %s" % (dir["guiTest"], dir["guiTestReport"], server_type),
        ],
        "environment": {
            "TEST_CONTEXT": suite,
            "CACHE_ENDPOINT": {
                "from_secret": "cache_public_s3_server",
            },
            "CACHE_BUCKET": {
                "from_secret": "cache_public_s3_bucket",
            },
        },
        "when": {
            "status": [
                "failure",
            ],
            "event": [
                "pull_request",
            ],
        },
    }]

def githubComment(alternateSuiteName, server_type = "oc10"):
    prefix = "Results for <strong>%s</strong> ${DRONE_BUILD_LINK}/${DRONE_JOB_NUMBER}${DRONE_STAGE_NUMBER}/1" % alternateSuiteName
    return [{
        "name": "github-comment",
        "image": THEGEEKLAB_DRONE_GITHUB_COMMENT,
        "settings": {
            "message": "%s/comments.file" % dir["guiTestReport"],
            "key": "pr-${DRONE_PULL_REQUEST}-%s" % server_type,
            "update": "true",
            "api_key": {
                "from_secret": "github_token",
            },
        },
        "commands": [
            "if [ -s %s/comments.file ]; then echo '%s' | cat - %s/comments.file > temp && mv temp %s/comments.file && /bin/drone-github-comment; fi" % (dir["guiTestReport"], prefix, dir["guiTestReport"], dir["guiTestReport"]),
        ],
        "when": {
            "status": [
                "failure",
            ],
            "event": [
                "pull_request",
            ],
        },
    }]

def cancelPreviousBuilds():
    return [{
        "kind": "pipeline",
        "type": "docker",
        "name": "cancel-previous-builds",
        "clone": {
            "disable": True,
        },
        "steps": [{
            "name": "cancel-previous-builds",
            "image": OC_CI_DRONE_CANCEL_PREVIOUS_BUILDS,
            "settings": {
                "DRONE_TOKEN": {
                    "from_secret": "drone_token",
                },
            },
        }],
        "trigger": {
            "event": [
                "pull_request",
            ],
        },
    }]

def skipIfUnchanged(ctx, type):
    if ("full-ci" in ctx.build.title.lower()):
        return []

    base = [
        "^.github/.*",
        "^.vscode/.*",
        "^changelog/.*",
        "README.md",
        ".gitignore",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "COPYING",
        "COPYING.documentation",
    ]

    skip = []
    if type == "unit-tests":
        skip = base + [
            "^test/gui/.*",
        ]

    if type == "gui-tests":
        skip = base + [
            "^test/([^g]|g[^u]|gu[^i]).*",
        ]

    return [{
        "name": "skip-if-unchanged",
        "image": OC_CI_DRONE_SKIP_PIPELINE,
        "settings": {
            "ALLOW_SKIP_CHANGED": skip,
        },
        "when": {
            "event": [
                "pull_request",
            ],
        },
    }]

def stepDependsOn(steps = []):
    if type(steps) == dict:
        steps = [steps]
    return getPipelineNames(steps)

def getPipelineNames(pipelines = []):
    names = []
    for pipeline in pipelines:
        names.append(pipeline["name"])
    return names

def pipelineDependsOn(pipeline, dependant_pipelines):
    if "depends_on" in pipeline.keys():
        pipeline["depends_on"] = pipeline["depends_on"] + getPipelineNames(dependant_pipelines)
    else:
        pipeline["depends_on"] = getPipelineNames(dependant_pipelines)
    return pipeline

def pipelinesDependsOn(pipelines, dependant_pipelines):
    pipes = []
    for pipeline in pipelines:
        pipes.append(pipelineDependsOn(pipeline, dependant_pipelines))

    return pipes
