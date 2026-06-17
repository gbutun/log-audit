FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    coreutils \
    grep \
    gawk \
    sed \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY web/requirements.txt ./web/requirements.txt
RUN pip install --no-cache-dir -r web/requirements.txt

COPY . .

EXPOSE 5055

CMD ["python", "web/app.py"]
