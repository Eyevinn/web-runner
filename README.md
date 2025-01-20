# web-runner

Docker container that clone a GitHub repository and run an NodeJS web application server.

## Usage

Build container image:

```
% docker build -t web-runner:local .
```

Run container providing a GitHub url and token:

```
% docker run --rm \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -e GITHUB_TOKEN=<token> \
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