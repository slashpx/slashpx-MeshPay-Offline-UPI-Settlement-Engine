# ---------- Stage 1: build the fat jar ----------
FROM maven:3.9.9-eclipse-temurin-17 AS build
WORKDIR /build

# Copy only the POM first so Maven's dependency layer is cached across code changes.
COPY pom.xml .
RUN mvn -B -q dependency:go-offline

COPY src ./src
RUN mvn -B -DskipTests package

# ---------- Stage 2: slim runtime ----------
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app

# Run as a non-root user.
RUN addgroup -S app && adduser -S app -G app
COPY --from=build /build/target/*.jar app.jar
USER app

# Render injects PORT; application.properties reads it (default 8080 for local runs).
EXPOSE 8080

# Container-aware heap sizing so the JVM respects Render's instance memory cap.
ENTRYPOINT ["sh","-c","java -XX:MaxRAMPercentage=75 -Djava.security.egd=file:/dev/./urandom -jar app.jar"]
