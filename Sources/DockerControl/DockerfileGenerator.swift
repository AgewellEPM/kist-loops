import Foundation

/// Generates a safe, pinned Dockerfile for a detected project kind. Pinned base
/// images, non-root user where the base supports it, minimal layers.
public struct DockerfileGenerator: Sendable {
    public init() {}

    public func dockerfile(for kind: ProjectKind) -> String? {
        switch kind {
        case .swift: return swift
        case .node: return node
        case .python: return python
        case .staticSite: return staticSite
        case .unknown: return nil
        }
    }

    private var swift: String {
        """
        FROM swift:5.9-slim
        WORKDIR /app
        COPY . .
        RUN swift build -c release
        # Run as a non-root user.
        RUN useradd -m runner && chown -R runner /app
        USER runner
        CMD ["swift", "run", "-c", "release"]
        """
    }

    private var node: String {
        """
        FROM node:20-slim
        WORKDIR /app
        COPY package*.json ./
        RUN npm ci --omit=dev || npm install --omit=dev
        COPY . .
        USER node
        CMD ["npm", "start"]
        """
    }

    private var python: String {
        """
        FROM python:3.12-slim
        WORKDIR /app
        COPY requirements.txt* pyproject.toml* ./
        RUN pip install --no-cache-dir -r requirements.txt || pip install --no-cache-dir .
        COPY . .
        RUN useradd -m runner && chown -R runner /app
        USER runner
        CMD ["python", "main.py"]
        """
    }

    private var staticSite: String {
        """
        FROM nginx:alpine
        COPY . /usr/share/nginx/html
        EXPOSE 80
        """
    }
}
