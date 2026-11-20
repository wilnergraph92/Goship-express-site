# An Image Key

Optional. Without one they get prompts in a file to paste into any image tool, and that costs nothing. Steps checked November 2026. One step per message, and wait for "done". If a button has moved, ask what they see and work it out with them.

Neither service has a free tier for these image models, so both need billing. Pick one. OpenAI is a little cheaper per image, and Gemini is handy if they already use Google.

`<ads-scripts>` is the `scripts` folder of the `ads` skill, and `<scripts>` is this skill's own.

## OpenAI

1. Go to https://platform.openai.com/api-keys and sign in or make an account. This is separate from a ChatGPT subscription.
2. Add credit at https://platform.openai.com/account/billing/overview . A small amount is enough, since each image costs cents.
3. Back on the keys page, click **Create** to make a new key. Copy it, and do not paste it into this chat.
4. OpenAI may ask them to verify their organization before it allows image models: https://developers.openai.com/api/docs/guides/image-generation

The line for the key file is `OPENAI_API_KEY`.

## Gemini

1. Go to https://aistudio.google.com/api-keys and sign in with a Google account.
2. Click **Create API key**. Copy it, and do not paste it into this chat. Help page: https://aistudio.google.com/docs/api-key
3. Set up billing when it offers it. Image models have no free tier.

The line for the key file is `GEMINI_API_KEY`.

## Then

```
<python> <ads-scripts>/setup_check.py keyfile --add OPENAI_API_KEY --open
```

Use the right name for the one they chose. They paste the key after the equals sign, then save and close.

Prove it works:

```
<python> <scripts>/make_images.py --check
```

The right result says the key works. This makes nothing and spends nothing, and it cannot tell whether billing is set up. The first real image will. Then:

```
<python> <ads-scripts>/setup_check.py mark images done
```
