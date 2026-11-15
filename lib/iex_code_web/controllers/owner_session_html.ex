defmodule IexCodeWeb.OwnerSessionHTML do
  use IexCodeWeb, :html

  def new(assigns) do
    assigns = Map.put(assigns, :form, to_form(%{}, as: :owner))

    ~H"""
    <main id="owner-login-stage">
      <canvas id="owner-login-aurora-canvas" aria-hidden="true"></canvas>
      <div class="login-aurora-vignette" aria-hidden="true"></div>
      <div class="login-aurora-noise" aria-hidden="true"></div>

      <section class="login-aurora-card-slot" aria-labelledby="owner-login-heading">
        <div class="login-aurora-shell">
          <div class="login-aurora-core">
            <div class="login-aurora-brand-row">
              <div class="login-aurora-brand-mark">
                <span class="login-aurora-orb" aria-hidden="true"></span>
                <span>IexCode · Aurora</span>
              </div>
              <span class="login-aurora-pill">
                <.icon name="hero-lock-closed-micro" class="size-3.5 text-cyan-300" />
                <span>Prism Vault</span>
              </span>
            </div>

            <div class="login-aurora-topline" aria-hidden="true"></div>

            <header>
              <h1 id="owner-login-heading" class="login-aurora-title">Owner sign in</h1>
              <p class="login-aurora-subtitle">
                Private access to your autonomous engineering workspace.
              </p>
            </header>

            <p :if={@error} id="owner-login-error" role="alert" class="login-aurora-error">
              <.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0 text-rose-400" />
              <span>{@error}</span>
            </p>

            <.form
              for={@form}
              id="owner-login-form"
              action={~p"/login"}
              method="post"
              class="login-aurora-form"
            >
              <.input
                field={@form[:username]}
                id="owner-username"
                label="Username"
                class="login-aurora-input"
                autocomplete="username"
                required
                maxlength="64"
              />
              <.input
                field={@form[:password]}
                id="owner-password"
                type="password"
                label="Password"
                class="login-aurora-input"
                autocomplete="current-password"
                required
                maxlength="1024"
              />
              <button id="owner-login-submit" class="login-aurora-submit" type="submit">
                <span>Sign in</span>
                <.icon name="hero-arrow-right-micro" class="login-aurora-submit-arrow size-4" />
              </button>
            </.form>

            <div class="login-aurora-footer">
              <span class="inline-flex items-center gap-1.5">
                <.icon name="hero-shield-check-micro" class="size-3.5 text-cyan-300/80" />
                <span>Encrypted owner session</span>
              </span>
              <span>TLS · PBKDF2</span>
            </div>
          </div>
        </div>
      </section>
    </main>
    """
  end
end
