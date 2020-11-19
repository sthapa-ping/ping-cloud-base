#!/bin/sh -ex

pip install --upgrade pip
pip3 install git-remote-codecommit --no-warn-script-location

cp /usr/local/bin/git-remote-codecommit /tools
cp /usr/local/lib/python3.7/site-packages/git_remote_codecommit/__init__.py /tools

# On the ArgoCD container, python3 is available under /usr/bin/python3
sed -i 's|/usr/local/bin/python|/usr/bin/python3|' /tools/git-remote-codecommit
chmod a+x /tools/git-remote-codecommit