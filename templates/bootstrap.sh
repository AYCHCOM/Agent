#!/bin/bash

BUILDBOX_PROMPT="\033[90m$\033[0m"

function buildbox-exit-if-failed {
  if [ $1 -ne 0 ]
  then
    exit $1
  fi
}

function buildbox-run {
  echo -e "$BUILDBOX_PROMPT $1"
  eval $1
  buildbox-exit-if-failed $?
}

echo '--- setup environment'

# Provide a default BUILDBOX_DIR
if [ -z "$BUILDBOX_DIR" ]; then
  # This will return the location of this file. We assume that the buildbox-artifact
  # tool is in the same folder. You can of course customize the locations
  # and edit this file.
  BUILDBOX_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
fi

# If no BUILDBOX_BIN_DIR has been provided, make one up
if [ -z "$BUILDBOX_BIN_DIR" ]; then
  if [ -d "$BUILDBOX_DIR/bin" ]; then
    BUILDBOX_BIN_DIR="$BUILDBOX_DIR/bin"
  else
    BUILDBOX_BIN_DIR="$BUILDBOX_DIR"
  fi
fi

# Add the $BUILDBOX_BIN to the $PATH
export PATH="$BUILDBOX_BIN_DIR:$PATH"

# Create the build directory
SANITIZED_AGENT_NAME=$(echo $BUILDBOX_AGENT_NAME | tr -d '"')
BUILDBOX_BUILD_DIR="$SANITIZED_AGENT_NAME/$BUILDBOX_PROJECT_SLUG"

# Show the ENV variables if DEBUG is on
if [ "$BUILDBOX_AGENT_DEBUG" == "true" ]
then
  buildbox-run "env | grep BUILDBOX"
fi

buildbox-run "mkdir -p \"$BUILDBOX_BUILD_DIR\""
buildbox-run "cd \"$BUILDBOX_BUILD_DIR\""

# Do we need to do a git checkout?
if [ ! -d ".git" ]
then
  # If it's a first time SSH git clone it will prompt to accept the host's
  # fingerprint. To avoid this add the host's key to ~/.ssh/known_hosts ahead
  # of time:
  #   ssh-keyscan -H host.com >> ~/.ssh/known_hosts
  buildbox-run "git clone "$BUILDBOX_REPO" . -qv"
fi

# Default empty branch names
if [ "$BUILDBOX_BRANCH" == "" ]
then
  BUILDBOX_BRANCH="master"
fi

buildbox-run "git clean -fdq"
buildbox-run "git fetch -q"

# Only reset to the branch if we're not on a tag
if [ "$BUILDBOX_TAG" == "" ]
then
buildbox-run "git reset --hard origin/$BUILDBOX_BRANCH"
fi

buildbox-run "git checkout -qf \"$BUILDBOX_COMMIT\""

if [ "$BUILDBOX_SCRIPT_PATH" == "" ]
then
  echo "ERROR: No script to run. Please go to \"Project Settings\" and configure your build step's \"Script to Run\""
  exit 1
fi

## Docker
if [ "$BUILDBOX_DOCKER" != "" ]
then
  DOCKER_CONTAINER="buildbox_"$BUILDBOX_JOB_ID"_container"
  DOCKER_IMAGE="buildbox_"$BUILDBOX_JOB_ID"_image"

  function docker-cleanup {
    docker rm -f $DOCKER_CONTAINER
    docker rmi -f $DOCKER_IMAGE
  }

  trap docker-cleanup EXIT

  # Build the Docker image, namespaced to the job
  buildbox-run "docker build -t $DOCKER_IMAGE ."

  echo "--- running $BUILDBOX_SCRIPT_PATH (in Docker container $DOCKER_IMAGE)"

  # Run the build script command in a one-off container
  buildbox-run "docker run --name $DOCKER_CONTAINER $DOCKER_IMAGE ./$BUILDBOX_SCRIPT_PATH"

## Fig
elif [ "$BUILDBOX_FIG_CONTAINER" != "" ]
then
  # Fig strips dashes and underscores, so we'll remove them to match the docker container names
  FIG_PROJ_NAME="buildbox"${BUILDBOX_JOB_ID//-}
  # The name of the docker container fig creates when it creates the adhoc run
  FIG_CONTAINER_NAME=$FIG_PROJ_NAME"_"$BUILDBOX_FIG_CONTAINER

  function fig-cleanup {
    fig -p $FIG_PROJ_NAME kill
    fig -p $FIG_PROJ_NAME rm --force
    # The adhoc run container isn't cleaned up by fig, so we have to do it ourselves
    echo "Killing "$FIG_CONTAINER_NAME"_run_1..."
    docker rm -f $FIG_CONTAINER_NAME"_run_1"
    # Kill the base image - this means it'll be built from scratch each time
    docker rmi -f $FIG_CONTAINER_NAME
  }

  trap fig-cleanup EXIT

  # Build the Docker images using Fig, namespaced to the job
  buildbox-run "fig -p $FIG_PROJ_NAME build"

  echo "--- running $BUILDBOX_SCRIPT_PATH (in Fig container '$BUILDBOX_FIG_CONTAINER')"

  # Run the build script command in the service specified in BUILDBOX_FIG_CONTAINER
  buildbox-run "fig -p $FIG_PROJ_NAME run $BUILDBOX_FIG_CONTAINER ./$BUILDBOX_SCRIPT_PATH"

## Standard
else
  echo "--- running $BUILDBOX_SCRIPT_PATH"

  # Run the step's build script
  ."/$BUILDBOX_SCRIPT_PATH"
fi

# Capture the exit status for the end
EXIT_STATUS=$?

if [ "$BUILDBOX_ARTIFACT_PATHS" != "" ]
then
  # NOTE: In agent version 1.0 and above, the location and the name of the
  # buildbox artifact binary changed. As of this verison, builbdox-artifact has
  # been rolled into buildbox-agent, and now lives in the $BUILDBOX_DIR/bin
  # directory.
  if [[ -e $BUILDBOX_DIR/bin/buildbox-agent ]]
  then
    # If you want to upload artifacts to your own server, uncomment the lines below
    # and replace the AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY with keys to your
    # own bucket.
    #
    # export AWS_SECRET_ACCESS_KEY=yyy
    # export AWS_ACCESS_KEY_ID=xxx
    # export AWS_S3_ACL=private
    # buildbox-run "buildbox-agent build-artifact upload \"$BUILDBOX_ARTIFACT_PATHS\" \"s3://name-of-your-s3-bucket/$BUILDBOX_JOB_ID\""

    # Show the output of the artifact uploder when in debug mode
    if [ "$BUILDBOX_AGENT_DEBUG" == "true" ]
    then
      echo '--- uploading artifacts'
      buildbox-run "buildbox-agent build-artifact upload \"$BUILDBOX_ARTIFACT_PATHS\""
      buildbox-exit-if-failed $?
    else
      buildbox-run "buildbox-agent build-artifact upload \"$BUILDBOX_ARTIFACT_PATHS\" > /dev/null 2>&1"
      buildbox-exit-if-failed $?
    fi
  elif [[ -e $BUILDBOX_DIR/buildbox-artifact ]]
  then
    # If you want to upload artifacts to your own server, uncomment the lines below
    # and replace the AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY with keys to your
    # own bucket.
    # export AWS_SECRET_ACCESS_KEY=yyy
    # export AWS_ACCESS_KEY_ID=xxx
    # buildbox-run "buildbox-artifact upload \"$BUILDBOX_ARTIFACT_PATHS\" "s3://name-of-your-s3-bucket/$BUILDBOX_JOB_ID" --url $BUILDBOX_AGENT_API_URL > /dev/null 2>&1"

    # By default we silence the buildbox-artifact build output. However, if you'd like to see
    # it in your logs, remove the: > /dev/null 2>&1 from the end of the line.
    buildbox-run "buildbox-artifact upload \"$BUILDBOX_ARTIFACT_PATHS\" --url $BUILDBOX_AGENT_API_URL > /dev/null 2>&1"
    buildbox-exit-if-failed $?
  else
    echo >&2 "ERROR: buildbox-artifact could not be found in $BUILDBOX_DIR"
    exit 1
  fi
fi

exit $EXIT_STATUS
