# Docker 이미지 빌드 및 ECR Push 설계

날짜: 2026-08-07

## 배경

현재 워크플로(`.github/workflows/actions.yml`)는 두 개의 잡으로 구성돼 있다.

- `unit-test` — pnpm 의존성 설치 후 vitest 실행
- `test-auth` — OIDC로 AWS 인증하고 ECR에 로그인한 뒤, registry 값을 echo로 출력

즉 인증까지만 검증된 상태이고 이미지는 아직 만들지 않는다. `Dockerfile`은 Next.js standalone 출력을 사용하는 멀티스테이지(`base` → `deps` → `builder` → `runner`) 구성으로 이미 준비돼 있다.

이번 작업의 목표는 인증 이후에 Docker 이미지를 빌드해 ECR로 push하는 단계를 추가하는 것이다.

## 범위

포함:

- ECR 리포지토리 수동 생성 절차 (1회)
- IAM Role에 push 권한 부여
- `test-auth` 잡을 `build-and-push`로 승격하고 빌드/push 스텝 추가
- commit SHA와 `latest` 두 개의 태그로 push
- GitHub Actions 캐시를 이용한 Docker 레이어 캐싱

제외:

- EC2 배포(SSH 또는 SSM) — 다음 단계에서 진행한다
- Terraform 등 IaC를 통한 인프라 관리
- 최소권한 IAM 정책으로의 축소

## 사전 준비

AWS 측 준비는 워크플로 밖에서 사람이 1회 수행한다. 워크플로가 리포지토리를 생성하도록 만들 수도 있지만, 그러면 IAM Role에 `ecr:CreateRepository` 권한이 필요해지고 워크플로가 인프라 프로비저닝 책임까지 떠안게 된다. 인프라 생성과 배포의 책임을 분리한다.

### ECR 리포지토리 생성

```bash
aws ecr create-repository \
  --repository-name auto-deployment \
  --region ap-northeast-2 \
  --image-scanning-configuration scanOnPush=true
```

리포지토리 이름은 프로젝트명과 동일한 `auto-deployment`로 한다.

생성 결과의 `repositoryUri`는 확인용일 뿐 어디에도 저장하지 않는다. 워크플로는 ECR 로그인 액션이 반환하는 registry 값에 리포지토리 이름을 붙여 이미지 URI를 조립하므로, AWS 계정 ID를 secrets나 코드에 중복 관리할 필요가 없다.

### IAM Role 권한

`secrets.AWS_ROLE_ARN`이 가리키는 Role에 다음 권한이 필요하다.

- `ecr:GetAuthorizationToken` (이미 보유 — 기존 로그인 스텝이 성공했으므로)
- `ecr:BatchCheckLayerAvailability`
- `ecr:InitiateLayerUpload`
- `ecr:UploadLayerPart`
- `ecr:CompleteLayerUpload`
- `ecr:PutImage`
- `ecr:BatchGetImage` — 캐시 조회에 필요

관리형 정책 `AmazonEC2ContainerRegistryPowerUser`를 연결하면 위 권한이 모두 포함된다. 최소권한으로 좁히는 작업은 별도 단계로 미룬다.

## 워크플로 설계

### 잡 그래프

```
push(main) → unit-test → build-and-push
```

`unit-test` 잡은 변경하지 않는다. 테스트가 실패하면 이미지를 만들지 않는다는 기존 게이트가 그대로 유지된다.

`test-auth` 잡은 `build-and-push`로 이름과 역할을 바꾼다. ECR 로그인으로 획득한 자격 증명은 잡 경계를 넘어 유지되지 않으므로, 로그인과 push는 같은 잡 안에 있어야 한다. 별도 잡으로 분리하면 AWS 인증과 ECR 로그인을 그대로 반복해야 한다.

기존 `Verify Login Success` 스텝은 삭제한다. push가 성공하는 것이 곧 인증이 동작한다는 증거이므로 echo 검증은 역할을 다했다.

### 워크플로 상단

- `name`: `Step 1 - Test & AWS/ECR Auth` → `Step 2 - Test, Build & Push to ECR`
- `env`에 `ECR_REPOSITORY: auto-deployment` 추가

리포지토리 이름은 민감정보가 아니므로 secrets 대신 `env`에 평문으로 둔다. 로그에서 마스킹되지 않아 디버깅이 쉽다.

### build-and-push 잡

```yaml
  build-and-push:
    needs: unit-test
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v6.2.3
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      # 레이어 캐시를 GitHub Actions 캐시에 저장하려면 buildx 가 필요하다
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push image to ECR
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}:${{ github.sha }}
            ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
          provenance: false
```

## 설계 판단

### 이미지 URI 조립

계정 ID를 secrets에 넣는 대신 `steps.login-ecr.outputs.registry`에서 받아온다. ECR 로그인 액션이 이미 계정 ID를 알고 있으므로 중복 관리할 이유가 없다.

### 태깅 전략

두 개의 태그를 동시에 붙인다.

- `${{ github.sha }}` — 어떤 커밋에서 나온 이미지인지 추적하고 롤백 대상을 특정하기 위한 불변 태그
- `latest` — 배포 단계에서 참조할 이동식 태그

### cache-to mode=max

기본값 `mode=min`은 최종 이미지에 포함된 레이어만 캐시한다. 이 Dockerfile은 무거운 작업(`pnpm install`, `next build`)이 전부 중간 스테이지인 `deps`와 `builder`에 있고, 최종 `runner` 스테이지는 빌드 산출물만 복사한다. 따라서 `mode=min`으로는 정작 느린 단계가 캐시되지 않는다. `mode=max`는 중간 스테이지 레이어까지 저장한다.

### provenance: false

buildx는 기본적으로 provenance attestation을 이미지와 함께 push한다. 그러면 ECR 콘솔에 태그 없는 `unknown/unknown` 아티팩트가 함께 나타나 목록이 지저분해진다. EC2에서 단순히 pull해 실행하는 용도라 attestation이 필요 없으므로 끈다.

### docker/build-push-action 사용

`docker build` + `docker push`를 run 스텝에서 직접 실행하는 방법보다 액션을 선택했다. 액션은 빌드·태깅·push를 한 스텝으로 처리하고, GitHub Actions 캐시 연동을 두 줄로 끝낸다. 직접 명령을 쓰면 매 실행마다 `pnpm install`부터 전부 다시 돌아 빌드가 수 분씩 걸린다.

## 검증

1. main에 push한 뒤 Actions 로그에서 `unit-test`와 `build-and-push`가 모두 성공하는지 확인한다.
2. 태그 두 개가 올라갔는지 CLI로 확인한다.

   ```bash
   aws ecr describe-images --repository-name auto-deployment --region ap-northeast-2 \
     --query 'imageDetails[].imageTags'
   ```

   결과에 해당 commit SHA와 `latest`가 함께 보여야 한다.

3. 캐시 동작은 두 번째 push부터 확인한다. 첫 실행은 캐시가 비어 있어 풀 빌드이고, 이후 소스만 변경된 커밋에서는 빌드 로그에 `CACHED`가 나타나며 실행 시간이 짧아져야 한다.

## 실패 모드

| 증상 | 원인 | 대응 |
| --- | --- | --- |
| `name unknown: The repository ... does not exist` | ECR 리포지토리 미생성 | 사전 준비의 create-repository 실행 |
| push 단계에서 `AccessDeniedException` | IAM Role에 push 권한 없음 | `AmazonEC2ContainerRegistryPowerUser` 연결 |
| 인증 자체가 실패 | OIDC 신뢰 정책의 sub 조건 불일치 | Role 신뢰 정책의 리포지토리/브랜치 조건 확인 |
| 캐시가 매번 미스 | 락파일 변경 또는 캐시 만료(7일 미사용) | 정상 동작. 락파일이 그대로인데 반복되면 mode 설정 확인 |

## 다음 단계

ECR에 이미지가 올라가는 것이 확인되면 5단계인 EC2 배포로 넘어간다. SSH와 SSM 중 어느 방식을 쓸지는 그때 별도로 설계한다.
