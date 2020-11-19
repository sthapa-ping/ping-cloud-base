#!/bin/sh -ex

pip install --upgrade pip
pip3 install git-remote-codecommit --no-warn-script-location

cp /usr/local/lib/python3.7/site-packages/git_remote_codecommit/__init__.py /tools

cp /usr/local/bin/git-remote-codecommit /tools
chmod a+x /tools/git-remote-codecommit