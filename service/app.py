import os
import socket

from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/")
def index():
    return jsonify(
        app=os.environ["APP_NAME"],
        version=os.environ["VERSION"],
        pod=socket.gethostname(),
    )


@app.get("/healthz")
def healthz():
    return jsonify(status="ok"), 200
