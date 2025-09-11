from telegram import Update, BotCommand
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes, PicklePersistence
import logging
import json
import os
import nest_asyncio
import asyncio
import re
import time


# 导入新的AI库
import google.generativeai as genai
import openai
from openai import AsyncOpenAI


# 应用nest_asyncio解决事件循环问题
nest_asyncio.apply()


# 设置日志到console和文件
logger = logging.getLogger()
logger.setLevel(logging.INFO)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
console_handler = logging.StreamHandler()
console_handler.setFormatter(formatter)
logger.addHandler(console_handler)
file_handler = logging.FileHandler('bot.log', encoding='utf-8')
file_handler.setFormatter(formatter)
logger.addHandler(file_handler)


# Bot Token
TOKEN = "7936113143:AAFjKv0VNRhZFVQpfGV_I-FjoAlVWuJYhpE" # <--- 请务必替换为您的真实Bot Token


# ======================= AI Engine Configuration =======================
AI_PROVIDER = "openai"
ENABLE_LLM_CHECK = True
GEMINI_API_KEY = ""
GEMINI_MODEL_NAME = ""
OPENAI_API_KEY = "4321" # <--- 请务必在这里填写您的真实、有效的密钥
OPENAI_MODEL_NAME = "DeepSeek-V3-Fast"
OPENAI_BASE_URL = "https://redundant-gisella-xiangyiyi-b59674e9.koyeb.app/v1"
# ========================================================================


# ================== Anti-Flood Configuration ======================
# بناءً على طلبك، تم تعطيل هذه الميزة.
ENABLE_ANTI_FLOOD = False # <--- 已根据您的要求，禁用防刷屏功能
FLOOD_MESSAGE_LIMIT = 3
FLOOD_TIME_WINDOW_SECONDS = 2
# ========================================================================


# 管理员ID
ADMIN_IDS = [1827922677, 6086963281, 5592393663]


# 关键词和白名单文件
KEYWORDS_FILE = "ad_keywords.json"
WHITELIST_FILE = "whitelist_users.json"



def load_keywords():
    if os.path.exists(KEYWORDS_FILE):
        with open(KEYWORDS_FILE, 'r', encoding='utf-8') as file:
            return json.load(file)
    else:
        default_keywords = ["广告", "优惠", "促销", "打折", "限时", "推广", "赞助", "ad", "advertisement", "promo", "discount", "sale", "sponsor"]
        save_keywords(default_keywords)
        return default_keywords


def save_keywords(keywords):
    with open(KEYWORDS_FILE, 'w', encoding='utf-8') as file:
        json.dump(keywords, file, ensure_ascii=False, indent=4)


def load_whitelist():
    if os.path.exists(WHITELIST_FILE):
        with open(WHITELIST_FILE, 'r', encoding='utf-8') as file:
            return json.load(file)
    save_whitelist([])
    return []


def save_whitelist(user_ids):
    with open(WHITELIST_FILE, 'w', encoding='utf-8') as file:
        json.dump(user_ids, file, ensure_ascii=False, indent=4)



AD_KEYWORDS = load_keywords()
WHITELIST_USERS = load_whitelist()



def is_admin(user_id):
    return user_id in ADMIN_IDS


def is_whitelisted(user_id):
    return user_id in WHITELIST_USERS


async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("你好！我是一个去广告机器人。管理员、白名单用户和白名单频道发送的消息不会被删除。")


async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    basic_help = """
    基本使用指南:
    /start - 启动机器人
    /help - 显示帮助信息


    将我添加到群组并给予删除消息权限，我会自动检测和删除广告消息。
    管理员、白名单用户和白名单频道发送的消息不会被删除。
    """
    admin_help = """


    管理员命令:
    /addkw [关键词] - 添加广告关键词
    /delkw [关键词] - 删除广告关键词
    /listkw - 列出所有广告关键词


    /addwl [用户或频道ID] - 添加到白名单
    /delwl [用户或频道ID] - 从白名单移除
    /listwl - 列出所有白名单
    """
    if is_admin(user_id):
        await update.message.reply_text(basic_help + admin_help)
    else:
        await update.message.reply_text(basic_help)


async def add_keyword(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_admin(user_id):
        await update.message.reply_text("抱歉，只有管理员才能使用此命令。")
        return
    if not context.args:
        await update.message.reply_text("请提供要添加的关键词，多个关键词用空格分隔。")
        return
    new_keywords = context.args
    global AD_KEYWORDS
    AD_KEYWORDS = load_keywords()
    added_keywords, existing_keywords = [], []
    for keyword in new_keywords:
        if keyword not in AD_KEYWORDS:
            AD_KEYWORDS.append(keyword)
            added_keywords.append(keyword)
        else:
            existing_keywords.append(keyword)
    save_keywords(AD_KEYWORDS)
    response = []
    if added_keywords: response.append(f"成功添加 {len(added_keywords)} 个关键词: {', '.join(added_keywords)}")
    if existing_keywords: response.append(f"已存在的关键词: {', '.join(existing_keywords)}")
    await update.message.reply_text("\n".join(response) if response else "没有添加任何新关键词。")


async def remove_keyword(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_admin(user_id):
        await update.message.reply_text("抱歉，只有管理员才能使用此命令。")
        return
    if not context.args:
        await update.message.reply_text("请提供要删除的关键词，多个关键词用空格分隔。")
        return
    keywords_to_remove = context.args
    global AD_KEYWORDS
    AD_KEYWORDS = load_keywords()
    removed_keywords, not_found_keywords = [], []
    for keyword in keywords_to_remove:
        if keyword in AD_KEYWORDS:
            AD_KEYWORDS.remove(keyword)
            removed_keywords.append(keyword)
        else:
            not_found_keywords.append(keyword)
    save_keywords(AD_KEYWORDS)
    response = []
    if removed_keywords: response.append(f"成功删除 {len(removed_keywords)} 个关键词: {', '.join(removed_keywords)}")
    if not_found_keywords: response.append(f"未找到的关键词: {', '.join(not_found_keywords)}")
    await update.message.reply_text("\n".join(response) if response else "没有删除任何关键词。")


async def list_keywords(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_admin(user_id):
        await update.message.reply_text("抱歉，只有管理员才能使用此命令。")
        return
    global AD_KEYWORDS
    AD_KEYWORDS = load_keywords()
    if not AD_KEYWORDS:
        await update.message.reply_text("广告关键词列表为空。")
        return
    keywords_text = "当前广告关键词列表：\n" + "\n".join(f"{i}. {kw}" for i, kw in enumerate(AD_KEYWORDS, 1))
    await update.message.reply_text(keywords_text)


async def add_whitelist_user(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id):
        await update.message.reply_text("抱歉，只有管理员才能使用此命令。")
        return
    if not context.args:
        await update.message.reply_text("请提供要添加的用户或频道ID，多个ID用空格分隔。")
        return
    global WHITELIST_USERS
    added_users, invalid_users, existing_users = [], [], []
    for id_str in context.args:
        try:
            entity_id = int(id_str)
            if entity_id not in WHITELIST_USERS:
                WHITELIST_USERS.append(entity_id)
                added_users.append(str(entity_id))
            else:
                existing_users.append(str(entity_id))
        except ValueError:
            invalid_users.append(id_str)
    save_whitelist(WHITELIST_USERS)
    response = []
    if added_users: response.append(f"成功添加 {len(added_users)} 个ID到白名单: {', '.join(added_users)}")
    if existing_users: response.append(f"已在白名单中的ID: {', '.join(existing_users)}")
    if invalid_users: response.append(f"无效的ID: {', '.join(invalid_users)}")
    await update.message.reply_text("\n".join(response) if response else "没有添加任何新ID。")


async def remove_whitelist_user(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id):
        await update.message.reply_text("抱歉，只有管理员才能使用此命令。")
        return
    if not context.args:
        await update.message.reply_text("请提供要移除的用户或频道ID，多个ID用空格分隔。")
        return
    global WHITELIST_USERS
    removed_users, not_found_users = [], []
    for id_str in context.args:
        try:
            entity_id = int(id_str)
            if entity_id in WHITELIST_USERS:
                WHITELIST_USERS.remove(entity_id)
                removed_users.append(str(entity_id))
            else:
                not_found_users.append(str(entity_id))
        except ValueError:
            not_found_users.append(id_str)
    save_whitelist(WHITELIST_USERS)
    response = []
    if removed_users: response.append(f"成功从白名单移除 {len(removed_users)} 个ID: {', '.join(removed_users)}")
    if not_found_users: response.append(f"未在白名单中找到的ID: {', '.join(not_found_users)}")
    await update.message.reply_text("\n".join(response) if response else "没有移除任何ID。")


async def list_whitelist_users(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id):
        await update.message.reply_text("抱歉，只有管理员才能使用此命令。")
        return
    global WHITELIST_USERS
    if not WHITELIST_USERS:
        await update.message.reply_text("白名单当前为空。")
        return
    users_text = "当前白名单ID列表 (用户和频道):\n" + "\n".join(f"{i}. {uid}" for i, uid in enumerate(WHITELIST_USERS, 1))
    await update.message.reply_text(users_text)



def clean_text(text):
    return re.sub(r'[\W_]+', '', text, flags=re.UNICODE)


def is_ad(text: str) -> bool:
    if not text: return False
    raw_text, clean_msg = text.lower(), clean_text(text.lower())
    for keyword in AD_KEYWORDS:
        raw_keyword, clean_keyword = keyword.lower(), clean_text(keyword.lower())
        if raw_keyword in raw_text or clean_keyword in clean_msg:
            return True
    return False


async def _is_ad_by_gemini(text: str) -> bool:
    try:
        model = genai.GenerativeModel(GEMINI_MODEL_NAME)
        prompt = """You are a Telegram group's content moderator... Your response must be "AD" or "NOT_AD"."""
        response = await model.generate_content_async(prompt)
        result = response.text.strip().upper()
        logger.info(f"[Gemini] Analysis result for '{text[:50]}...': {result}")
        return result == "AD"
    except Exception as e:
        logger.error(f"[Gemini] API call error: {e}")
        return False


async def _is_ad_by_openai(text: str) -> bool:
    """[Internal] Ad detection using an OpenAI-compatible API with an improved prompt and safer check."""
    try:
        client = AsyncOpenAI(api_key=OPENAI_API_KEY, base_url=OPENAI_BASE_URL)
        system_prompt = """
        你是一个Telegram群组内容审查员，职责是精准识别广告。
        你的判断必须非常严格，只有在满足以下【广告特征】时才能判定为广告。
        正常的聊天、技术讨论、日常分享、即使是推荐某个东西，只要不带强烈的商业推广意图，都不能算作广告。


        【广告特征】（需要满足至少一条）：
        1. 带有明确的商业推广、销售产品或服务的意图。
        2. 包含引诱用户私聊、点击链接去购买或参与活动的呼吁性用语。
        3. 大段的、与当前聊天氛围无关的营销文案。
        4. 重复发送相似的推广内容。


        你的回答必须且只能是以下两个词之一：
        - 如果确定是广告，回答 "AD"
        - 如果不确定，或认为是正常聊天，回答 "NOT_AD"
        """
        response = await client.chat.completions.create(
            model=OPENAI_MODEL_NAME,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": text},
            ],
            max_tokens=5,
            temperature=0.0,
        )
        result = response.choices[0].message.content.strip().upper()
        logger.info(f"[OpenAI] Analysis result for '{text[:50]}...': {result}")
        return result == "AD"
    except Exception as e:
        logger.error(f"[OpenAI] API call error: {e}")
        return False


async def is_ad_by_llm(text: str) -> bool:
    if not text: return False
    if AI_PROVIDER == 'gemini': return await _is_ad_by_gemini(text)
    elif AI_PROVIDER == 'openai': return await _is_ad_by_openai(text)
    logger.warning(f"Invalid AI_PROVIDER '{AI_PROVIDER}'. Skipping LLM check.")
    return False


async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    message = update.message
    if not (message and message.chat.type in ["group", "supergroup"]):
        return


    author_id, author_name = None, "某用户"
    if message.from_user:
        user = message.from_user
        author_id, author_name = user.id, user.full_name
    elif message.sender_chat:
        channel = message.sender_chat
        author_id, author_name = channel.id, channel.title


    if not author_id: return


    if is_admin(author_id) or is_whitelisted(author_id):
        if is_whitelisted(author_id):
            logger.info(f"Author {author_id} ({author_name}) is on the whitelist, skipping all checks.")
        return


    # 由于 ENABLE_ANTI_FLOOD 已被设置为 False，下面的整个 'if' 代码块将不会被执行。
    if ENABLE_ANTI_FLOOD:
        current_time = time.time()
        if 'flood_tracker' not in context.chat_data:
            context.chat_data['flood_tracker'] = {}
        
        tracker = context.chat_data['flood_tracker']
        history = tracker.get(author_id, [])
        
        history = [t for t in history if current_time - t < FLOOD_TIME_WINDOW_SECONDS]
        history.append(current_time)
        tracker[author_id] = history
        
        logger.info(f"[Anti-Flood DEBUG] Chat: {message.chat.id}, Author: {author_id}, Message Count: {len(history)}")
        
        if len(history) > FLOOD_MESSAGE_LIMIT:
            logger.info(f"Anti-flood TRIGGERED in chat {message.chat.id} for {author_name} ({author_id}). Deleting message {message.message_id}.")
            try:
                await message.delete()
            except Exception as e:
                logger.warning(f"Failed to delete flood message {message.message_id}: {e}")
            return

    # ==================== MODIFICATION START ====================
    # 同时获取新消息和被引用消息的内容
    new_message_content = message.text or message.caption or ""
    quoted_content = ""
    if message.reply_to_message:
        quoted_content = message.reply_to_message.text or message.reply_to_message.caption or ""
    
    # 将两者合并，以换行符分隔，用于后续检测
    content_to_check = f"{new_message_content}\n{quoted_content}".strip()
    # ===================== MODIFICATION END =====================
    
    fields_to_check = [("消息内容", content_to_check)]
    if message.from_user:
        fields_to_check.extend([("名", message.from_user.first_name or ""), ("姓", message.from_user.last_name or ""), ("用户名", message.from_user.username or "")])
    elif message.sender_chat:
        fields_to_check.append(("频道标题", message.sender_chat.title or ""))
        
    hit_field = None
    for field_name, field_value in fields_to_check:
        if field_value and is_ad(field_value):
            # 如果是引用消息触发，在日志中进行标注
            if quoted_content and is_ad(quoted_content) and not is_ad(new_message_content):
                hit_field = f"引用的{field_name}命中关键词"
            else:
                hit_field = f"{field_name}命中关键词"
            break
    
    if not hit_field and ENABLE_LLM_CHECK and content_to_check:
        if await is_ad_by_llm(content_to_check):
             # AI检测同样可以增加对引用内容的判断逻辑，为简化，此处统一标注
            if quoted_content and (await is_ad_by_llm(quoted_content)) and not (await is_ad_by_llm(new_message_content)):
                hit_field = f"AI模型分析(引用内容) ({AI_PROVIDER})"
            else:
                hit_field = f"AI模型分析({AI_PROVIDER})"


    if hit_field:
        logger.info(f"AD detected. Author: {author_name} ({author_id}), Reason: {hit_field}, Content: '{content_to_check}'")
        try:
            await message.delete()
            notification_text = f"已删除来自 {author_name} 的疑似广告（检测方式：{hit_field}）。"
            notification = await context.bot.send_message(chat_id=message.chat_id, text=notification_text)
            await asyncio.sleep(5)
            await notification.delete()
        except Exception as e:
            logger.error(f"Failed to delete message: {e}")


async def error_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    logger.error(f"Update {update} caused error {context.error}")


async def main(): 
    persistence = PicklePersistence(filepath="bot_data.pickle")
    application = Application.builder().token(TOKEN).persistence(persistence).build()


    global ENABLE_LLM_CHECK
    if ENABLE_LLM_CHECK:
        logger.info(f"LLM check is enabled. Provider: {AI_PROVIDER}")
        if AI_PROVIDER == 'openai':
            if not OPENAI_API_KEY: 
                logger.warning("Disabling LLM check: OPENAI_API_KEY is not set.")
                ENABLE_LLM_CHECK = False
            else: 
                logger.info(f"OpenAI-style client configured. Model: {OPENAI_MODEL_NAME}, Base URL: {OPENAI_BASE_URL or 'Default'}")
        else:
            logger.error(f"Invalid AI_PROVIDER '{AI_PROVIDER}'. Disabling LLM check.")
            ENABLE_LLM_CHECK = False
            
    await application.bot.set_my_commands([
        BotCommand("start", "启动机器人"),
        BotCommand("help", "查看帮助信息"),
        BotCommand("addkw", "添加关键词 [仅管理员]"),
        BotCommand("delkw", "删除关键词 [仅管理员]"),
        BotCommand("listkw", "查看关键词列表 [仅管理员]"),
        BotCommand("addwl", "添加白名单ID [仅管理员]"),
        BotCommand("delwl", "移除白名单ID [仅管理员]"),
        BotCommand("listwl", "查看白名单列表 [仅管理员]"),
    ])
    application.add_handler(CommandHandler("start", start_command))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CommandHandler("addkw", add_keyword))
    application.add_handler(CommandHandler("delkw", remove_keyword))
    application.add_handler(CommandHandler("listkw", list_keywords))
    application.add_handler(CommandHandler("addwl", add_whitelist_user))
    application.add_handler(CommandHandler("delwl", remove_whitelist_user))
    application.add_handler(CommandHandler("listwl", list_whitelist_users))
    
    new_filter = filters.ChatType.GROUPS & filters.ALL & ~filters.COMMAND
    application.add_handler(MessageHandler(new_filter, handle_message))
    
    application.add_error_handler(error_handler)


    logger.info("Bot starting with all features and fixes...")
    await application.run_polling()


if __name__ == "__main__":
    asyncio.run(main())
