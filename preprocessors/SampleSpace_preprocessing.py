from pathlib import Path
import sys
import librosa
import matplotlib.pyplot as plt
sys.path.insert(0, str(Path(__file__).parent.parent))
from mmm_python import *
from umap import UMAP
from sklearn.preprocessing import StandardScaler, MinMaxScaler

d = {
    "path": "user_files/resources/shoe-squeak.wav",
    "thresh":10.0,
    "window_size":1024,
    "hop_size":512
}

y, sr = librosa.load(d["path"], sr=None)

onsets = MBufAnalysis.spectral_flux_onsets(d)
onsets -= d["hop_size"] * 2
np.insert(onsets,0,0)
np.append(onsets,len(y))

print("num onsets:", len(onsets))
diff_secs = np.diff(onsets) / sr
print("avg time between onsets:", np.mean(diff_secs))
print("median time between onsets:", np.median(diff_secs))
print("std time between onsets:", np.std(diff_secs))
print("min time between onsets:", np.min(diff_secs))
print("max time between onsets:", np.max(diff_secs))

# plt.figure(figsize=(10, 4))
# plt.plot(y, label="Audio Signal")
# plt.vlines(onsets, ymin=np.min(y), ymax=np.max(y), color='r', label="Onsets")
# # display x-axis in seconds instead of samples
# tick_sec = 5
# plt.xticks(np.arange(0, len(y), sr * tick_sec), [str(i) for i in np.arange(0, len(y)/sr, tick_sec)])

# plt.title("Audio Signal with Detected Onsets")
# plt.xlabel("Time (s)")
# plt.ylabel("Amplitude")
# plt.legend()
# plt.tight_layout()
# plt.show()

mfccs = np.ndarray((len(onsets)-1, 13))

d["num_coeffs"] = 14

for i in range(len(onsets)-1):
    start = int(onsets[i])
    end = int(onsets[i+1])
    print(f"Slice {i} / {len(onsets)-1}: start={start}, end={end}, duration={(end-start)/sr:.2f} seconds")
    d["start_frame"] = start
    d["num_frames"] = end - start
    mfccs_slice = MBufAnalysis.mfcc(d)
    mfccs[i] = mfccs_slice[:, 1:].mean(axis=0)

print("mfccs.shape:", mfccs.shape)

mfccs_scaled = StandardScaler().fit_transform(mfccs)

umap = UMAP(n_components=2,learning_rate=0.1,min_dist=0.01,n_epochs=200)
mfccs_umap = umap.fit_transform(mfccs_scaled)

print("mfccs_umap.shape:", mfccs_umap.shape)

# plt.figure(figsize=(8, 6))
# plt.scatter(mfccs_umap[:, 0], mfccs_umap[:, 1], c='blue', edgecolor='k')
# plt.title("UMAP Projection of MFCCs")
# plt.xlabel("UMAP Dimension 1")
# plt.ylabel("UMAP Dimension 2")
# plt.grid()
# plt.tight_layout()
# plt.show()

mfccs_umap_scaled = MinMaxScaler().fit_transform(mfccs_umap)
print("mfccs_umap_scaled.shape:", mfccs_umap_scaled.shape)

from lloyd import *

field = Field(mfccs_umap_scaled)

# plot the field.voronoi diagram
# plt.figure(figsize=(8, 6))
# plt.scatter(field.points[:, 0], field.points[:, 1], c='blue', edgecolor='k')
# plt.title("Initial Voronoi Points")
# plt.xlabel("UMAP Dimension 1")
# plt.ylabel("UMAP Dimension 2")
# plt.grid()
# plt.tight_layout()
# plt.show()

# relax the field n times and plot the voronoi diagram after each relaxation
for i in range(20):
  field.relax()
#   plt.figure(figsize=(8, 6))
#   plt.scatter(field.points[:, 0], field.points[:, 1], c='blue', edgecolor='k')
#   plt.title(f"Voronoi Points after {i+1} Relaxations")
#   plt.xlabel("UMAP Dimension 1")
#   plt.ylabel("UMAP Dimension 2")
#   plt.grid()
#   plt.tight_layout()
#   plt.show()

plt.figure(figsize=(8, 6))
plt.scatter(field.points[:, 0], field.points[:, 1], c='blue', edgecolor='k')
plt.title("Voronoi Points")
plt.xlabel("UMAP Dimension 1")
plt.ylabel("UMAP Dimension 2")
plt.grid()
plt.tight_layout()
plt.show()

# for i in range(len(field.points)):
#     print(f"Point {i}: {field.points[i]}")
#     print("slice start:", onsets[i])
#     print("slice end:", onsets[i+1])

out_dict = {}
out_dict["points"] = field.points.tolist()
starts = onsets[:-1].tolist()
num_frames = (onsets[1:] - onsets[:-1]).tolist()
out_dict["start_frame_num_frames"] = list(zip(starts, num_frames))
out_dict["path"] = d["path"]

filename = f"user_files/SampleSpace_{Path(d['path']).stem}.json"

import json

with open(filename, "w") as f:
    json.dump(out_dict, f, indent=4)