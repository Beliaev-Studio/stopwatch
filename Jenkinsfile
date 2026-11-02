/*
 * Every branch builds one release artifact; a master build deploys that artifact to production
 * after a click on the approval button, or automatically when a line of the built commit's message is
 * exactly [deploy-prod]. There is no sandbox.
 *
 * Requires the Docker Pipeline, Pipeline: Milestone Step, Lockable Resources, SSH Agent, Credentials
 * Binding, Git and Workspace Cleanup plugins and an agent with Docker.
 */

// Runs build and deployment commands with Node.js, PHP, Composer and SSH.
def insideCi(Closure body) {
  docker.image('cimmwolf/vistro:3').inside('-u root:root') {
    try {
      body()
    } finally {
      // Files created by root must stay removable by the Jenkins agent.
      sh 'chown -R "$(stat -c %u:%g .)" .'
    }
  }
}

def isProductionBranch() {
  return env.BRANCH_NAME == 'master' && !env.CHANGE_ID && !env.TAG_NAME
}

def autoDeployProduction = false

pipeline {
  agent none
  options {
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }
  environment {
    // vistro-26 (Hosts/Vistro/bootstrap.sh), shared with CRM_GF, BPM and DSystem.
    DEPLOY_HOST             = 'deploy@45.66.118.106'
    SSH_CREDENTIALS         = 'c98cafdc-9af0-4637-b970-6cc7f2305852'
    // Secret file with the known_hosts line of the server's ED25519 key.
    KNOWN_HOSTS_CREDENTIALS = 'dsystem-known-hosts'
    ARTIFACT                = 'stopwatch.vistro.ru.tar.gz'
  }
  stages {
    stage('Build') {
      agent any
      stages {
        stage('Package') {
          steps {
            script {
              // Read only the built commit, not earlier messages in the changelog.
              def commitMessage = sh(returnStdout: true, script: 'git -c safe.directory="$WORKSPACE" log -1 --format=%B "$GIT_COMMIT"')
              // Only a line of its own counts, so a message that merely mentions the marker still needs approval.
              autoDeployProduction = isProductionBranch() && (commitMessage =~ /(?m)^\s*\[deploy-prod\]\s*$/).find()
              currentBuild.description = env.GIT_COMMIT.take(8)
              if (autoDeployProduction) {
                currentBuild.description += ' [deploy-prod]'
              }
              insideCi {
                // gulp minifies style.css and the images in place, polymer build writes build/default.
                // Node 22 loads the ESM gulpfile through require(), which fails on its top-level await.
                sh '''
                  npm ci --no-audit --no-fund
                  NODE_OPTIONS=--no-experimental-require-module npx gulp publish
                  npx polymer build
                  test -s build/default/index.html
                  cp nginx.conf build/default/nginx.conf
                  tar -czf "$ARTIFACT" -C build/default .
                '''
              }
            }
            stash name: 'artifact', includes: env.ARTIFACT
          }
        }
      }
      post {
        always {
          cleanWs()
        }
      }
    }
    stage('Approve') {
      when {
        expression { isProductionBranch() }
      }
      steps {
        // A newer build that reaches this point supersedes older pending approvals.
        milestone(ordinal: currentBuild.number, label: 'Built')
        script {
          if (autoDeployProduction) {
            echo 'Публикация на прод разрешена меткой [deploy-prod] в сообщении собираемого коммита.'
          } else {
            timeout(time: 3, unit: 'DAYS') {
              input message: 'Выложить эту сборку на stopwatch.vistro.ru?', ok: 'Выложить'
            }
          }
        }
        // Approved builds stay above later builds' milestones, so a newer build cannot interrupt production.
        // Leave room for the plugin's completion milestone.
        milestone ordinal: Integer.MAX_VALUE - 1, label: 'Production approved'
      }
    }
    stage('Production') {
      when {
        // Skip before taking an agent, so branch builds do not check out the repository for nothing.
        beforeAgent true
        expression { isProductionBranch() }
      }
      agent any
      steps {
        unstash 'artifact'
        lock('stopwatch-deploy') {
          script {
            // The timestamp names the release directory on the server.
            def releaseId = sh(returnStdout: true, script: "date -u '+%Y%m%d%H%M%S'").trim()
            withEnv(["RELEASE_ID=${releaseId}"]) {
              insideCi {
                sshagent(credentials: [env.SSH_CREDENTIALS]) {
                  withCredentials([file(credentialsId: env.KNOWN_HOSTS_CREDENTIALS, variable: 'KNOWN_HOSTS')]) {
                    sh './deploy.sh "$ARTIFACT"'
                  }
                }
              }
            }
          }
        }
      }
      post {
        always {
          cleanWs()
        }
      }
    }
  }
}
