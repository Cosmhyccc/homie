/// Where a voice conversation is. Shared by the notch UI and both brains (local homie and cloud max).
enum VoiceState { case idle, connecting, listening, speaking, closing, failed }
