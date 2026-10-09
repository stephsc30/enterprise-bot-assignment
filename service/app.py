import os
import socket
from pathlib import Path

from flask import Flask, jsonify

app = Flask(__name__)


def read_setting(name):
    value = os.environ[name]
    config_dir = os.environ.get("CONFIG_DIR")
    if config_dir:
        value = (Path(config_dir) / name).read_text(encoding="utf-8")
    return value


@app.get("/")
def index():
    return jsonify(
        app=read_setting("APP_NAME"),
        version=read_setting("VERSION"),
        pod=socket.gethostname(),
    )


@app.get("/healthz")
def healthz():
    return jsonify(status="ok"), 200
