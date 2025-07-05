# web-runner

Docker container that clones a GitHub repository containing a NodeJS web application. Build and runs the NodeJS application. Available as an open web service in [Eyevinn Open Source Cloud](https://docs.osaas.io/osaas.wiki/Service%3A-Web-Runner.html).

[![Badge OSC](https://img.shields.io/badge/Evaluate-24243B?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iMTIiIGZpbGw9InVybCgjcGFpbnQwX2xpbmVhcl8yODIxXzMxNjcyKSIvPgo8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI3IiBzdHJva2U9ImJsYWNrIiBzdHJva2Utd2lkdGg9IjIiLz4KPGRlZnM%2BCjxsaW5lYXJHcmFkaWVudCBpZD0icGFpbnQwX2xpbmVhcl8yODIxXzMxNjcyIiB4MT0iMTIiIHkxPSIwIiB4Mj0iMTIiIHkyPSIyNCIgZ3JhZGllbnRVbml0cz0idXNlclNwYWNlT25Vc2UiPgo8c3RvcCBzdG9wLWNvbG9yPSIjQzE4M0ZGIi8%2BCjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iIzREQzlGRiIvPgo8L2xpbmVhckdyYWRpZW50Pgo8L2RlZnM%2BCjwvc3ZnPgo%3D)](https://app.osaas.io/browse/eyevinn-web-runner)

## Usage

Build container image:

```
% docker build -t web-runner:local .
```

### Source code on GitHub

Run container providing a GitHub url and token:

```
% docker run --rm \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -e GITHUB_TOKEN=<token> \
  -p 8080:8080 web-runner:local
```

The web application is now available at http://localhost:8080

### Source code on S3 bucket

Source code can be packaged into a zip file and uploaded to an S3 bucket. To create the zip file go to the projects directory and run.

```
% zip -r ../my-app.zip ./
```

Copy this file to the S3 bucket and then run container providing S3 URL and access credentials. In this example an S3 bucket on a MinIO server in OSC

```
% docker run --rm \
  -e SOURCE_URL=s3://code/my-app.zip \
  -e S3_ENDPOINT_URL=https://eyevinnlab-birme.minio-minio.auto.prod.osaas.io \
  -e AWS_ACCESS_KEY_ID=<username> \
  -e AWS_SECRET_ACCESS_KEY=<password> \
  -p 8080:8080 web-runner:local
```

The web application is now available at http://localhost:8080

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md)

## License

This project is licensed under the MIT License, see [LICENSE](LICENSE).

# Support

Join our [community on Slack](http://slack.streamingtech.se) where you can post any questions regarding any of our open source projects. Eyevinn's consulting business can also offer you:

- Further development of this component
- Customization and integration of this component into your platform
- Support and maintenance agreement

Contact [sales@eyevinn.se](mailto:sales@eyevinn.se) if you are interested.

# About Eyevinn Technology

[Eyevinn Technology](https://www.eyevinntechnology.se) is an independent consultant firm specialized in video and streaming. Independent in a way that we are not commercially tied to any platform or technology vendor. As our way to innovate and push the industry forward we develop proof-of-concepts and tools. The things we learn and the code we write we share with the industry in [blogs](https://dev.to/video) and by open sourcing the code we have written.

Want to know more about Eyevinn and how it is to work here. Contact us at work@eyevinn.se!
