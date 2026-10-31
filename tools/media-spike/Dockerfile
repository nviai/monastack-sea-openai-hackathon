FROM python:3.12-slim@sha256:aa943ce411423c7582288f18707ff66eddcbaeb510502d747a72aeb34f30d159
WORKDIR /probe
COPY requirements.lock /probe/requirements.lock
RUN pip install --no-cache-dir -r /probe/requirements.lock
COPY client_probe.py /probe/client_probe.py
USER 65534:65534
ENTRYPOINT ["python", "/probe/client_probe.py"]
