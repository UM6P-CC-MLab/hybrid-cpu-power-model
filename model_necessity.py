import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns

# Set academic styling matching your color palette preferences
plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman"],
    "mathtext.fontset": "stix",
    "text.usetex": False, # Switch to True if your local environment has LaTeX configured
    "axes.edgecolor": "#111111",
    "axes.linewidth": 1.0
})

# Define the precise color palette matching your figures
color_measured = "#1f4e79"        # Deep elegant blue
color_coarse = "#c0412c"          # Clean dark red/peach tint
color_fine = "#2c8558"            # Muted academic green
color_temp = "#e3c16f"            # Soft gold/peach tone
color_fill_coarse = "#f7ebe8"     # Light neutral fill for panel a
color_fill_fine = "#eef6f2"       # Light neutral fill for panel b

# Create synthetic data closely matching the structural behavior of your plot
np.random.seed(42)
time = np.linspace(0, 300, 61)

# Temperature profile (constant high, then thermal throttling/drop, then stabilizing)
tmax = np.zeros_like(time)
tmax[time <= 50] = 96
tmax[(time > 50) & (time <= 90)] = 96 - (96 - 63) * (time[(time > 50) & (time <= 90)] - 50) / 40
tmax[time > 90] = 63 + np.random.choice([-1, 0, 1], size=len(time[time > 90])) * 0.8
tmax[12] = 62; tmax[15] = 62; tmax[25] = 64; tmax[27] = 64 # adding minor variations

# Measured Power
measured = np.zeros_like(time)
measured[time <= 10] = 7.9
measured[(time > 10) & (time <= 75)] = 7.9 - (7.9 - 2.3) * (time[(time > 10) & (time <= 75)] - 10) / 65
measured[time > 75] = 2.35 + np.random.normal(0, 0.08, len(time[time > 75]))
# Add the dynamic oscillations during the high-load drop phase
measured[(time > 15) & (time <= 55)] += np.sin(time[(time > 15) & (time <= 55)] * 0.3) * 0.4

# Coarse-grained model (underestimates constant baseline leakage at high & low temperatures)
coarse = np.zeros_like(time)
coarse[time <= 10] = 6.5
coarse[(time > 10) & (time <= 75)] = 6.5 - (6.5 - 1.95) * (time[(time > 10) & (time <= 75)] - 10) / 65
coarse[time > 75] = 1.98 + np.random.normal(0, 0.04, len(time[time > 75]))

# Fine-grained model (accurately tracks both dynamic shifts and leakage profiles)
fine = measured - np.random.normal(0, 0.05, len(time))
fine[time <= 20] = 7.0 - (7.0 - 6.3) * (time[time <= 20]) / 20
fine[(time > 20) & (time <= 75)] = measured[(time > 20) & (time <= 75)] - 0.25 * (75 - time[(time > 20) & (time <= 75)]) / 55

# Setup plot figure
fig, (ax1, ax3) = plt.subplots(1, 2, figsize=(12, 4.5), sharey=True, dpi=300)

# =========================================================================
# PANEL (a): Coarse-grained model (Dynamic-only)
# =========================================================================
ax1.plot(time, measured, color=color_measured, linewidth=2.2, label="Measured")
ax1.plot(time, coarse, color=color_coarse, linewidth=1.8, linestyle="--", label="Coarse-grained model")

# Fill gap indicating omission or under-estimation
ax1.fill_between(time, measured, coarse, where=(measured > coarse), color=color_fill_coarse, alpha=0.7)

ax2 = ax1.twinx()
ax2.plot(time, tmax, color=color_temp, linewidth=1.5, label=r"$T_{\max}$")

# Axis adjustments for Panel a
ax1.set_title("(a) Dynamic-only model", fontsize=11, pad=10)
ax1.set_xlabel("Time [s]", fontsize=11)
ax1.set_ylabel("CPU Power [W]", fontsize=11)
ax2.set_ylabel(r"$T_{\max}$ [$^\circ$C]", color=color_temp, fontsize=11)
ax1.set_xlim(0, 300)
ax1.set_ylim(0, 8.2)
ax2.set_ylim(55, 100)
ax2.tick_params(axis='y', labelcolor=color_temp)

# Legend orchestration
lines1, labels1 = ax1.get_legend_handles_labels()
lines2, labels2 = ax2.get_legend_handles_labels()
ax1.legend(lines1 + lines2, labels1 + labels2, loc="center right", bbox_to_anchor=(0.98, 0.5), frameon=True, fontsize=9.5)

# =========================================================================
# PANEL (b): Fine-grained model (Hybrid)
# =========================================================================
ax3.plot(time, measured, color=color_measured, linewidth=2.2, label="Measured")
ax3.plot(time, fine, color=color_fine, linewidth=1.8, linestyle="--", label="Our fine-grained model")

# Fill highlighting high accuracy tracking
ax3.fill_between(time, measured, fine, color=color_fill_fine, alpha=0.5)

ax4 = ax3.twinx()
ax4.plot(time, tmax, color=color_temp, linewidth=1.5, label=r"$T_{\max}$")

# Axis adjustments for Panel b
ax3.set_title("(b) Hybrid model (dynamic + leakage)", fontsize=11, pad=10)
ax3.set_xlabel("Time [s]", fontsize=11)
ax4.set_ylabel(r"$T_{\max}$ [$^\circ$C]", color=color_temp, fontsize=11)
ax3.set_xlim(0, 300)
ax4.set_ylim(55, 100)
ax4.tick_params(axis='y', labelcolor=color_temp)

# Legend orchestration
lines3, labels3 = ax3.get_legend_handles_labels()
lines4, labels4 = ax4.get_legend_handles_labels()
ax3.legend(lines3 + lines4, labels3 + labels4, loc="center right", bbox_to_anchor=(0.98, 0.5), frameon=True, fontsize=9.5)

plt.tight_layout()
plt.savefig("model_necessity_high_res.pdf", format="pdf", bbox_inches="tight")
plt.savefig("model_necessity_high_res.png", format="png", dpi=300, bbox_inches="tight")
plt.show()