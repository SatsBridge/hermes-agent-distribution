#!@python@/bin/python3 -I
import sys

sys.path.insert(0, "@skills_library@")
from skills_acl import main

main("@setfacl@")
